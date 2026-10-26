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
export interface ClientBilling { client_id: string; billing_name: string | null; billing_email: string | null; gst_number: string | null; billing_address: string | null; payment_terms_days: number; currency: string }
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
