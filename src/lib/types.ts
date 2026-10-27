// Row types for the tables the UI reads. Keep in sync with supabase/migrations.
// (Regenerate with `supabase gen types typescript` once a Supabase project is linked.)

export type EmployeeStatus = 'onboarding' | 'probation' | 'active' | 'notice_period' | 'exited'
export type EmploymentType = 'full_time' | 'part_time' | 'contract' | 'intern' | 'consultant'
export type ClientStatus = 'lead' | 'onboarding' | 'active' | 'paused' | 'churned'
export type ServiceType = 'seo' | 'google_ads' | 'meta_ads' | 'social_media' | 'website_development' | 'local_seo' | 'youtube' | 'email_marketing' | 'other'
export type ProjectStatus = 'planning' | 'active' | 'on_hold' | 'completed' | 'cancelled'
export type Priority = 'low' | 'medium' | 'high' | 'urgent'
export type StatusCategory = 'todo' | 'in_progress' | 'review' | 'changes_requested' | 'done' | 'cancelled'

export const SERVICE_TYPES: ServiceType[] = ['seo', 'google_ads', 'meta_ads', 'social_media', 'website_development', 'local_seo', 'youtube', 'email_marketing', 'other']
export const SERVICE_LABELS: Record<ServiceType, string> = {
  seo: 'SEO', google_ads: 'Google Ads', meta_ads: 'Meta Ads', social_media: 'Social Media Marketing', website_development: 'Website Development',
  local_seo: 'Local SEO & GBP', youtube: 'YouTube Marketing', email_marketing: 'Email Marketing', other: 'Other',
}
export const serviceLabel = (s?: string | null) => (s ? SERVICE_LABELS[s as ServiceType] ?? s : '')
export const PRIORITIES: Priority[] = ['low', 'medium', 'high', 'urgent']

export interface Organization { id: string; name: string; slug: string; timezone: string; currency: string; employee_code_prefix: string }
export interface Profile { id: string; org_id: string | null; client_id: string | null; full_name: string; email: string; avatar_url: string | null; is_active: boolean }
export interface Role { id: string; org_id: string; key: string; name: string; description: string | null; is_system: boolean; is_client_role: boolean }
export interface Department { id: string; name: string }

export interface Employee {
  id: string; org_id: string; profile_id: string | null; employee_code: string; full_name: string; work_email: string
  work_phone: string | null; department_id: string | null; designation: string | null; reporting_manager_id: string | null
  employment_type: EmploymentType; status: EmployeeStatus; joining_date: string; probation_end_date: string | null
  exit_date: string | null; exit_reason: string | null; work_schedule_id: string | null
}
export interface EmployeePrivate {
  employee_id: string; personal_email: string | null; personal_phone: string | null; date_of_birth: string | null; address: string | null
  emergency_contact_name: string | null; emergency_contact_relation: string | null; emergency_contact_phone: string | null
  pan_number: string | null; uan_number: string | null; bank_name: string | null; bank_account_number: string | null; bank_ifsc: string | null
}
export interface SalaryRevision { id: string; employee_id: string; effective_from: string; annual_ctc: number; monthly_components: Record<string, number>; reason: string | null; created_at: string }

export interface AttendanceRecord {
  id: string; employee_id: string; work_date: string; check_in_at: string; check_out_at: string | null
  break_minutes: number; worked_minutes: number | null; late_minutes: number; status: 'in_progress' | 'present' | 'half_day' | 'absent'; source: string
}
export interface AttendanceBreak { id: string; record_id: string; start_at: string; end_at: string | null }
export interface AttendanceCorrection {
  id: string; employee_id: string; work_date: string; requested_check_in: string; requested_check_out: string
  reason: string; status: 'pending' | 'approved' | 'rejected'; decision_note: string | null; created_at: string
}
export interface LeaveType { id: string; code: string; name: string; annual_quota: number | null; is_paid: boolean; allow_half_day: boolean; approval_levels: number; color: string; is_active: boolean }
export interface LeaveBalance { id: string; employee_id: string; leave_type_id: string; year: number; allocated: number; adjusted: number; used: number }
export interface LeaveRequest {
  id: string; employee_id: string; leave_type_id: string; start_date: string; end_date: string; half_day: 'none' | 'first_half' | 'second_half'
  days: number; reason: string | null; status: 'pending' | 'approved' | 'rejected' | 'cancelled'; current_level: number; required_levels: number; created_at: string
}
export interface Holiday { id: string; holiday_date: string; name: string; is_optional: boolean }

export interface Client {
  id: string; org_id: string; name: string; legal_name: string | null; industry: string | null; website: string | null; city: string | null
  status: ClientStatus; account_manager_id: string | null; brand_guidelines: string | null; created_at: string
}
export interface ClientContact { id: string; client_id: string; name: string; designation: string | null; email: string | null; phone: string | null; is_primary: boolean }
export interface ClientService { id: string; client_id: string; service: ServiceType; description: string | null; start_date: string | null; end_date: string | null; status: string }
export interface ClientBilling { client_id: string; billing_name: string | null; billing_email: string | null; gst_number: string | null; billing_address: string | null; payment_terms_days: number; currency: string; state_code: string | null }
export interface Contract { id: string; client_id: string; title: string; start_date: string; end_date: string | null; billing_cycle: string; management_fee: number; auto_renew: boolean; renewal_reminder_days: number; status: string }
export interface ClientNote { id: string; client_id: string; author_id: string; channel: string; body: string; created_at: string }

export interface Project {
  id: string; org_id: string; client_id: string | null; parent_project_id: string | null; name: string; description: string | null
  service: ServiceType | null; owner_id: string | null; status: ProjectStatus; priority: Priority; start_date: string | null; due_date: string | null
  budget_amount: number | null; client_visible: boolean; created_at: string
}
export interface ProjectOverview extends Project { total_tasks: number; completed_tasks: number; progress_pct: number; client_name: string | null }
export interface ProjectMember { project_id: string; profile_id: string; project_role: 'manager' | 'member' | 'viewer' }
export interface Milestone { id: string; project_id: string; title: string; due_date: string | null; completed_at: string | null; client_visible: boolean; position: number }

export interface TaskStatus { id: string; key: string; name: string; category: StatusCategory; position: number; color: string; is_default: boolean }
export interface Task {
  id: string; org_id: string; project_id: string; client_id: string | null; parent_task_id: string | null; title: string; description: string | null
  status_id: string; priority: Priority; reviewer_id: string | null; start_date: string | null; due_date: string | null
  estimated_minutes: number | null; position: number; client_visible: boolean; created_by: string | null; completed_at: string | null; created_at: string
}
export interface TaskComment { id: string; task_id: string; author_id: string; body: string; is_internal: boolean; created_at: string; edited_at: string | null }

export interface Notification {
  id: string; type: string; title: string; body: string | null; link: string | null; read_at: string | null; created_at: string
}
export interface Announcement { id: string; title: string; body: string; pinned: boolean; created_at: string }

export interface DashboardMetrics {
  today: string
  active_clients: number; active_projects: number; overdue_tasks: number; projects_at_risk: number; tasks_in_review: number
  my_open_tasks: number; my_due_today: number; my_overdue: number; my_reviews: number
  active_employees: number; checked_in_today: number; late_today: number; on_leave_today: number
  pending_leave_approvals: number; pending_corrections: number; probation_reviews_due: number; upcoming_renewals: number
  my_attendance_today: AttendanceRecord | null
  team_workload: { name: string; open_tasks: number; overdue: number }[]
  tasks_by_status: { name: string; color: string; position: number; count: number }[]
}

// ---------- Phase 4 ----------
export interface ProjectTemplate { id: string; org_id: string; name: string; service: ServiceType | null; description: string | null; default_duration_days: number; is_active: boolean }
export interface TemplateTask {
  id: string; template_id: string; title: string; description: string | null; priority: Priority; start_offset_days: number
  duration_days: number; estimated_minutes: number | null; client_visible: boolean; position: number
}
export interface RecurringRule {
  id: string; org_id: string; project_id: string; title: string; description: string | null; frequency: 'weekly' | 'monthly'
  weekday: number | null; day_of_month: number | null; due_after_days: number; assignee_id: string | null; reviewer_id: string | null
  priority: Priority; estimated_minutes: number | null; client_visible: boolean; start_date: string; end_date: string | null; is_active: boolean
}
export interface TimeEntry {
  id: string; org_id: string; profile_id: string; task_id: string; project_id: string; entry_date: string; started_at: string | null
  ended_at: string | null; minutes: number | null; source: 'timer' | 'manual'; note: string | null; billable: boolean; timesheet_id: string | null
}
export type TimesheetStatus = 'submitted' | 'approved' | 'rejected'
export interface Timesheet {
  id: string; profile_id: string; week_start: string; status: TimesheetStatus; total_minutes: number; submitted_at: string
  decided_by: string | null; decided_at: string | null; decision_note: string | null
}
export type ContentStatus = 'idea' | 'in_progress' | 'internal_review' | 'client_review' | 'changes_requested' | 'approved' | 'scheduled' | 'published' | 'cancelled'
export const CONTENT_STATUSES: ContentStatus[] = ['idea', 'in_progress', 'internal_review', 'client_review', 'changes_requested', 'approved', 'scheduled', 'published', 'cancelled']
export const CONTENT_PLATFORMS = ['instagram', 'facebook', 'linkedin', 'youtube', 'x', 'google_business', 'blog', 'email', 'other'] as const
export const CONTENT_TYPES = ['post', 'reel', 'story', 'carousel', 'video', 'short', 'blog', 'email', 'ad'] as const
export interface ContentItem {
  id: string; org_id: string; client_id: string; project_id: string | null; title: string; platform: (typeof CONTENT_PLATFORMS)[number]
  content_type: (typeof CONTENT_TYPES)[number]; caption: string | null; creative_url: string | null; scheduled_at: string | null
  status: ContentStatus; assignee_id: string | null; client_feedback: string | null; reviewed_by: string | null; reviewed_at: string | null
  published_url: string | null; published_at: string | null; created_by: string | null; created_at: string
}
export type CampaignPlatform = 'google_ads' | 'meta_ads' | 'other'
export interface Campaign {
  id: string; client_id: string; project_id: string | null; platform: CampaignPlatform; name: string; external_id: string | null; objective: string | null
  status: 'draft' | 'active' | 'paused' | 'ended'; start_date: string | null; end_date: string | null; monthly_budget: number | null; currency: string; client_visible: boolean
}
export interface CampaignSummary {
  campaign_id: string; client_id: string; platform: CampaignPlatform; name: string; status: string; monthly_budget: number | null; currency: string
  impressions: number; clicks: number; spend: number; conversions: number; conversion_value: number
  ctr_pct: number | null; cpc: number | null; cpa: number | null; roas: number | null; first_date: string | null; last_date: string | null
}
export interface CampaignMetric { campaign_id: string; metric_date: string; impressions: number; clicks: number; spend: number; conversions: number; conversion_value: number }
export interface CampaignImport {
  id: string; client_id: string; platform: string; file_name: string; rows_total: number; rows_inserted: number; rows_updated: number
  rows_skipped: number; campaigns_created: number; created_by: string | null; created_at: string
}
export interface EmploymentDocument { id: string; employee_id: string; doc_type: string; file_name: string; storage_path: string; uploaded_by: string | null; created_at: string }

// ---------- Phase 5 ----------
export type InvoiceStatus = 'draft' | 'issued' | 'partially_paid' | 'paid' | 'cancelled'
export interface BillingSettings {
  org_id: string; legal_name: string | null; gstin: string | null; pan: string | null; state_code: string | null; address: string | null
  email: string | null; phone: string | null; invoice_prefix: string; default_sac: string; default_gst_rate: number; ad_spend_gst_rate: number
  bank_details: string | null; terms: string | null
}
export interface InvoiceParty { name?: string; gstin?: string; pan?: string; state_code?: string; address?: string; email?: string; phone?: string; bank_details?: string; terms?: string }
export interface Invoice {
  id: string; org_id: string; client_id: string; contract_id: string | null; billing_period: string | null; invoice_number: string | null
  fiscal_year: string | null; status: InvoiceStatus; issue_date: string | null; due_date: string | null; place_of_supply: string | null
  tax_mode: 'intra' | 'inter'; currency: string; notes: string | null; seller: InvoiceParty | null; buyer: InvoiceParty | null
  fee_subtotal: number; ad_spend_subtotal: number; other_subtotal: number; taxable_total: number; cgst: number; sgst: number; igst: number
  round_off: number; total: number; amount_received: number; tds_deducted: number; balance: number
  created_by: string | null; issued_at: string | null; cancelled_at: string | null; cancel_reason: string | null; created_at: string
}
export interface InvoiceItem {
  id: string; invoice_id: string; kind: 'management_fee' | 'ad_spend' | 'other'; description: string; sac: string | null
  quantity: number; unit_price: number; gst_rate: number; amount: number; position: number
}
export interface Payment {
  id: string; invoice_id: string; amount: number; tds_amount: number; paid_on: string; method: string; reference: string | null
  note: string | null; recorded_by: string | null; created_at: string
}
export interface FinanceSummary {
  today: string; outstanding: number; overdue: number; overdue_count: number; open_count: number; draft_count: number
  invoiced_this_month: number; fees_this_month: number; ad_spend_this_month: number; collected_this_month: number
  aging: { current: number; d1_30: number; d31_60: number; d61_90: number; d90_plus: number }
  by_client: { client_id: string; name: string; balance: number; invoices: number; oldest_due: string }[]
}
export interface EmailSettings {
  org_id: string; enabled: boolean; app_url: string | null; from_name: string | null; reply_to: string | null
  send_notifications: boolean; send_invoices: boolean
}

export type PayrollStatus = 'draft' | 'finalized' | 'paid'
export interface PayrollRun {
  id: string; period_month: string; status: PayrollStatus; absent_as_lop: boolean; employees_count: number; gross_total: number
  deductions_total: number; net_total: number; missing_salary: { employee_id: string; name: string; code: string }[]
  created_at: string; finalized_at: string | null; paid_on: string | null
}
export interface PayslipComponent { code: string; name: string; full: number; amount: number }
export interface PayslipAdjustment { label: string; kind: 'earning' | 'deduction'; amount: number }
export interface Payslip {
  id: string; run_id: string; period_month: string; employee_id: string; employee_code: string; employee_name: string
  designation: string | null; department: string | null; joining_date: string | null; annual_ctc: number | null
  days_in_month: number; payable_days: number; lop_days: number; unpaid_leave_days: number; absent_days: number
  earnings: PayslipComponent[]; deductions: PayslipComponent[]; adjustments: PayslipAdjustment[]
  gross: number; total_deductions: number; net_pay: number
  bank: { pan?: string; uan?: string; bank_name?: string; account_number?: string; ifsc?: string }
}

export type OpeningStatus = 'draft' | 'open' | 'on_hold' | 'closed' | 'filled'
export type CandidateStage = 'applied' | 'screening' | 'interview' | 'offer' | 'hired' | 'rejected' | 'withdrawn'
export interface JobOpening {
  id: string; org_id: string; title: string; department_id: string | null; employment_type: EmploymentType; location: string | null
  positions: number; description: string | null; requirements: string | null; salary_min: number | null; salary_max: number | null
  status: OpeningStatus; hiring_manager_id: string | null; target_date: string | null; created_at: string
}
export interface OpeningPipeline {
  id: string; title: string; department_id: string | null; employment_type: EmploymentType; location: string | null; positions: number
  status: OpeningStatus; hiring_manager_id: string | null; target_date: string | null; created_at: string
  active: number; applied: number; screening: number; interview: number; offer: number; hired: number; closed: number
}
export interface Candidate {
  id: string; org_id: string; opening_id: string; full_name: string; email: string | null; phone: string | null; source: string
  referred_by: string | null; current_company: string | null; experience_years: number | null; current_ctc: number | null
  expected_ctc: number | null; notice_period_days: number | null; location: string | null; portfolio_url: string | null
  resume_path: string | null; resume_name: string | null; stage: CandidateStage; rejection_reason: string | null; rating: number | null
  notes: string | null; employee_id: string | null; stage_changed_at: string; created_at: string
}
export interface Interview {
  id: string; candidate_id: string; round_name: string; scheduled_at: string; duration_minutes: number; mode: 'in_person' | 'video' | 'phone'
  location: string | null; interviewer_id: string; status: 'scheduled' | 'completed' | 'cancelled' | 'no_show'; rating: number | null
  recommendation: 'strong_yes' | 'yes' | 'no' | 'strong_no' | null; feedback: string | null; feedback_at: string | null
}
export interface Offer {
  id: string; candidate_id: string; designation: string; department_id: string | null; annual_ctc: number; joining_date: string
  offer_date: string; valid_until: string | null; status: 'draft' | 'sent' | 'accepted' | 'declined' | 'withdrawn'; letter_text: string | null
  decided_at: string | null; created_at: string
}

// ---------- Platform admin ----------
export interface AccountState { platform_admin: boolean; org_status: 'active' | 'suspended' | null; org_creation: 'open' | 'invite_only' | 'closed' }
export interface PlatformAgency {
  id: string; name: string; slug: string; status: 'active' | 'suspended'; plan: string; max_users: number | null; created_at: string
  suspended_at: string | null; suspended_reason: string | null; platform_notes: string | null; founder: { name: string; email: string } | null
  staff_users: number; client_users: number; employees: number; clients: number; projects: number; invoices: number
  last_activity: string | null; is_platform_home: boolean
}
export interface PlatformMember { id: string; full_name: string; email: string; is_active: boolean; is_client: boolean; created_at: string; roles: string | null }
export interface PlatformInvite { id: string; email: string; plan: string | null; max_users: number | null; note: string | null; created_at: string; expires_at: string; used_at: string | null; used_by_org: string | null }
export interface PlatformSettings {
  settings: { org_creation: AccountState['org_creation']; default_plan: string; default_max_users: number | null }
  invites: PlatformInvite[]; admins: { user_id: string; name: string; email: string }[]
}
