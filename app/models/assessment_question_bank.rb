# frozen_string_literal: true

#
# Copyright (C) 2011 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class AssessmentQuestionBank < ActiveRecord::Base
  extend RootAccountResolver
  include Workflow

  belongs_to :context, polymorphic: [:account, :course]
  has_many :assessment_questions, -> { order("assessment_questions.name, assessment_questions.position, assessment_questions.created_at") }
  has_many :assessment_question_bank_users
  has_many :learning_outcome_alignments, -> { where("content_tags.tag_type='learning_outcome' AND content_tags.workflow_state<>'deleted'").preload(:learning_outcome) }, as: :content, inverse_of: :content, class_name: "ContentTag"
  has_many :quiz_groups, class_name: "Quizzes::QuizGroup"
  before_save :infer_defaults
  after_save :update_alignments
  validates :title, length: { maximum: maximum_string_length, allow_nil: true }
  resolves_root_account through: :context

  include MasterCourses::Restrictor
  restrict_columns :content, [:title]

  workflow do
    state :active
    state :deleted
  end

  set_policy do
    given do |user, session|
      context.grants_all_rights?(user, session, :read_question_banks, :manage_assignments_add)
    end
    can :read and can :create

    given do |user, session|
      context.grants_all_rights?(user, session, :read_question_banks, :manage_assignments_edit)
    end
    can :read and can :update and can :manage

    given do |user, session|
      context.grants_all_rights?(user, session, :read_question_banks, :manage_assignments_delete)
    end
    can :read and can :delete

    given { |user, session| context.grants_right?(user, session, :read_question_banks) }
    can :read

    given { |user| user && assessment_question_bank_users.where(user_id: user).exists? }
    can :read
  end

  def self.default_imported_title
    t :default_imported_title, "Imported Questions"
  end

  def self.default_unfiled_title
    t :default_unfiled_title, "Unfiled Questions"
  end

  def self.unfiled_for_context(context)
    return unless context

    context.assessment_question_banks.where(title: default_unfiled_title, workflow_state: "active").first_or_create
  end

  def cached_context_short_name
    @cached_context_name ||= Rails.cache.fetch(["short_name_lookup", context_code].cache_key) do
      context.try(:short_name) || ""
    end
  end

  def assessment_question_count
    assessment_questions.active.count
  end

  def context_code
    "#{context_type.underscore}_#{context_id}"
  end

  def infer_defaults
    self.title = t(:default_title, "No Name - %{course}", course: context.name) if title.blank?
  end

  def alignments=(alignments)
    # empty string from controller or empty hash
    outcomes = if alignments.empty?
                 []
               else
                 context.linked_learning_outcomes.where(id: alignments.keys.map(&:to_i)).to_a
               end

    # delete alignments that aren't in the list anymore
    if outcomes.empty?
      learning_outcome_alignments.update_all(workflow_state: "deleted")
    else
      learning_outcome_alignments
        .where.not(learning_outcome_id: outcomes)
        .update_all(workflow_state: "deleted")
    end

    # add/update current alignments
    unless outcomes.empty?
      alignments.each do |outcome_id, mastery_score|
        matching_outcome = outcomes.detect { |outcome| outcome.id == outcome_id.to_i }
        next unless matching_outcome

        matching_outcome.align(self, context, mastery_score:)
      end
    end
  end

  def update_alignments
    return unless saved_change_to_workflow_state? && deleted?

    LearningOutcome.update_alignments(self, context, [])
  end

  def bookmark_for(user, do_bookmark = true)
    if do_bookmark
      assessment_question_bank_users.where(user:).first_or_create!
    else
      AssessmentQuestionBankUser.where(user_id: user, assessment_question_bank_id: self).delete_all
    end
  end

  def bookmarked_for?(user)
    user && assessment_question_bank_users.where(user_id: user).exists?
  end

  def select_for_submission(quiz_id, quiz_group_id, count, exclude_ids = [], duplicate_index = 0)
    # 1. select a random set of questions from the DB
    questions = assessment_questions.active
    questions = questions.where.not(id: exclude_ids) unless exclude_ids.empty?
    questions = questions.reorder(Arel.sql("RANDOM()")).limit(count)
    # 2. process the questions in :id order to minimize the risk of deadlock
    aqs = questions.to_a.sort_by(&:id)
    quiz_questions = AssessmentQuestion.find_or_create_quiz_questions(aqs, quiz_id, quiz_group_id, duplicate_index)
    # 3. re-randomize the resulting questions
    quiz_questions.shuffle
  end

  alias_method :destroy_permanently!, :destroy
  def destroy
    self.workflow_state = "deleted"
    self.deleted_at = Time.now.utc
    save
  end

  # clear out all questions so that the bank can be replaced. this is currently
  # used by the respondus API.
  def clear_for_replacement
    assessment_questions.destroy_all
    quiz_groups.destroy_all
  end

  scope :active, -> { where("assessment_question_banks.workflow_state<>'deleted'") }
end
