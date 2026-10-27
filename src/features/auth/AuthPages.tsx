import { useState } from 'react'
import { Navigate } from 'react-router-dom'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Button, Card, CardBody, Field, Input } from '@/components/ui'
import { supabase } from '@/lib/supabase'
import { friendlyError } from '@/lib/errors'
import { useAuth } from './AuthProvider'

const signInSchema = z.object({ email: z.string().email('Enter a valid email'), password: z.string().min(8, 'At least 8 characters') })
const signUpSchema = signInSchema.extend({ full_name: z.string().trim().min(2, 'Enter your name') })
type SignUp = z.infer<typeof signUpSchema>

function Shell({ children, title, subtitle }: { children: React.ReactNode; title: string; subtitle: string }) {
  return (
    <main className="flex min-h-full items-center justify-center p-4">
      <div className="w-full max-w-md">
        <div className="mb-6 text-center">
          <div className="mx-auto mb-3 flex size-10 items-center justify-center rounded-lg bg-primary text-sm font-bold text-primary-foreground">D</div>
          <h1 className="text-xl font-semibold">{title}</h1>
          <p className="mt-1 text-sm text-muted-foreground">{subtitle}</p>
        </div>
        <Card><CardBody>{children}</CardBody></Card>
      </div>
    </main>
  )
}

export function LoginPage() {
  const { session, loading } = useAuth()
  const [mode, setMode] = useState<'signin' | 'signup' | 'reset'>('signin')
  const form = useForm<SignUp>({ resolver: zodResolver(mode === 'signup' ? signUpSchema : signInSchema) as never })
  if (!loading && session) return <Navigate to="/" replace />

  const onSubmit = form.handleSubmit(async (v) => {
    try {
      if (mode === 'signin') {
        const { error } = await supabase.auth.signInWithPassword({ email: v.email, password: v.password })
        if (error) throw error
      } else if (mode === 'signup') {
        const { error, data } = await supabase.auth.signUp({ email: v.email, password: v.password, options: { data: { full_name: v.full_name } } })
        if (error) throw error
        if (!data.session) toast.success('Check your inbox to confirm your email, then sign in.')
      }
    } catch (err) { toast.error(friendlyError(err)) }
  })

  const sendReset = async () => {
    const email = form.getValues('email')
    if (!email) return toast.error('Enter your email first')
    const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: window.location.origin })
    if (error) toast.error(friendlyError(error)); else toast.success('Password reset link sent if the account exists.')
  }

  const { errors, isSubmitting } = form.formState
  return (
    <Shell title={mode === 'signup' ? 'Create your account' : 'Sign in to Agency OS'}
      subtitle={mode === 'signup' ? 'Invited team members and clients: use the email you were invited with.' : 'Dotscube Digital Academy'}>
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        {mode === 'signup' && (
          <Field label="Full name" error={errors.full_name?.message}>{(p) => <Input {...p} autoComplete="name" {...form.register('full_name')} />}</Field>
        )}
        <Field label="Email" error={errors.email?.message}>{(p) => <Input {...p} type="email" autoComplete="email" {...form.register('email')} />}</Field>
        <Field label="Password" error={errors.password?.message}>
          {(p) => <Input {...p} type="password" autoComplete={mode === 'signup' ? 'new-password' : 'current-password'} {...form.register('password')} />}
        </Field>
        <Button type="submit" className="w-full" loading={isSubmitting}>{mode === 'signup' ? 'Create account' : 'Sign in'}</Button>
      </form>
      <div className="mt-4 flex justify-between text-sm">
        <Button variant="link" onClick={() => setMode(mode === 'signup' ? 'signin' : 'signup')}>
          {mode === 'signup' ? 'Have an account? Sign in' : 'New here? Create an account'}
        </Button>
        {mode === 'signin' && <Button variant="link" onClick={sendReset}>Forgot password?</Button>}
      </div>
    </Shell>
  )
}

const orgSchema = z.object({
  name: z.string().trim().min(2, 'Enter the agency name').max(120),
  slug: z.string().trim().toLowerCase().regex(/^[a-z0-9][a-z0-9-]{1,48}$/, 'Lowercase letters, numbers and dashes'),
  full_name: z.string().trim().min(2, 'Enter your name'),
})

export function OnboardingPage() {
  const { profile, refresh, signOut, session, account } = useAuth()
  const form = useForm<z.infer<typeof orgSchema>>({ resolver: zodResolver(orgSchema), defaultValues: { full_name: profile?.full_name ?? '' } })
  if (!session) return <Navigate to="/login" replace />
  if (profile?.org_id) return <Navigate to="/" replace />
  const onSubmit = form.handleSubmit(async (v) => {
    const { error } = await supabase.rpc('create_organization', { p_name: v.name, p_slug: v.slug, p_full_name: v.full_name })
    if (error) return toast.error(friendlyError(error))
    toast.success('Organization created')
    await refresh()
  })
  const { errors, isSubmitting } = form.formState
  const mode = account?.platform_admin ? 'open' : account?.org_creation ?? 'open'
  if (mode === 'closed') return (
    <Shell title="Your account isn't linked to an agency yet" subtitle="New agencies can't be created here right now.">
      <p className="text-sm text-muted-foreground">If your agency invited you, ask them to send the invitation to <strong>{profile?.email}</strong>, then sign out and sign in again.</p>
      <Button variant="link" className="mt-3" onClick={signOut}>Sign out ({profile?.email})</Button>
    </Shell>
  )
  return (
    <Shell title="Set up your agency" subtitle="If you were invited, ask your admin to resend the invitation to this email instead.">
      {mode === 'invite_only' && <p className="mb-4 rounded-md bg-muted p-3 text-sm">Creating an agency is by invitation. This works only if the platform owner invited <strong>{profile?.email}</strong>.</p>}
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        <Field label="Your name" error={errors.full_name?.message}>{(p) => <Input {...p} {...form.register('full_name')} />}</Field>
        <Field label="Agency name" error={errors.name?.message}>{(p) => <Input {...p} placeholder="Dotscube Digital" {...form.register('name')} />}</Field>
        <Field label="Short ID" hint="Used in links, e.g. dotscube" error={errors.slug?.message}>{(p) => <Input {...p} {...form.register('slug')} />}</Field>
        <Button type="submit" className="w-full" loading={isSubmitting}>Create organization</Button>
      </form>
      <Button variant="link" className="mt-3" onClick={signOut}>Sign out ({profile?.email})</Button>
    </Shell>
  )
}
