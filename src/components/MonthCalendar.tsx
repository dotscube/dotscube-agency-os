import type { ReactNode } from 'react'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { addMonths, format, parseISO } from 'date-fns'
import { cn } from '@/lib/utils'
import { isoDay, monthGrid } from '@/lib/dates'
import { Button } from '@/components/ui'

export interface CalendarItem { id: string; day: string; label: string; color?: string; muted?: boolean; onClick?: () => void; href?: string }

/** Month grid (Mon–Sun). On small screens it collapses to an agenda list of days that have items. */
export function MonthCalendar({ month, onMonthChange, items, toolbar, renderItem }: {
  month: string; onMonthChange: (m: string) => void; items: CalendarItem[]; toolbar?: ReactNode
  renderItem?: (i: CalendarItem) => ReactNode
}) {
  const days = monthGrid(month)
  const cur = parseISO(month).getMonth()
  const today = isoDay(new Date())
  const byDay = new Map<string, CalendarItem[]>()
  items.forEach((i) => byDay.set(i.day, [...(byDay.get(i.day) ?? []), i]))
  const go = (n: number) => onMonthChange(isoDay(addMonths(parseISO(month), n)))
  const chip = (i: CalendarItem) => renderItem ? renderItem(i) : (
    <button key={i.id} onClick={i.onClick} title={i.label}
      className={cn('block w-full truncate rounded px-1.5 py-0.5 text-left text-xs text-white hover:opacity-90', i.muted && 'opacity-60')}
      style={{ backgroundColor: i.color ?? '#2563eb' }}>{i.label}</button>)
  const agenda = days.filter((d) => parseISO(d).getMonth() === cur && byDay.has(d))
  return (
    <div className="rounded-lg border bg-card">
      <div className="flex flex-wrap items-center justify-between gap-2 border-b p-3">
        <div className="flex items-center gap-2">
          <Button size="icon" variant="outline" aria-label="Previous month" onClick={() => go(-1)}><ChevronLeft /></Button>
          <h2 className="min-w-36 text-center text-sm font-semibold">{format(parseISO(month), 'MMMM yyyy')}</h2>
          <Button size="icon" variant="outline" aria-label="Next month" onClick={() => go(1)}><ChevronRight /></Button>
          <Button size="sm" variant="ghost" onClick={() => onMonthChange(today)}>Today</Button>
        </div>
        {toolbar}
      </div>
      <div className="hidden md:block">
        <div className="grid grid-cols-7 border-b text-center text-xs font-medium text-muted-foreground">
          {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((d) => <div key={d} className="py-2">{d}</div>)}
        </div>
        <div className="grid grid-cols-7">
          {days.map((d) => {
            const list = byDay.get(d) ?? []
            return (
              <div key={d} className={cn('min-h-28 border-b border-r p-1.5 [&:nth-child(7n)]:border-r-0', parseISO(d).getMonth() !== cur && 'bg-muted/40')}>
                <div className={cn('mb-1 flex size-6 items-center justify-center rounded-full text-xs', d === today ? 'bg-primary font-semibold text-primary-foreground' : 'text-muted-foreground')}>
                  {parseISO(d).getDate()}</div>
                <div className="space-y-1">{list.slice(0, 4).map(chip)}
                  {list.length > 4 && <p className="px-1 text-xs text-muted-foreground">+{list.length - 4} more</p>}</div>
              </div>)
          })}
        </div>
      </div>
      <ul className="divide-y md:hidden">
        {agenda.length === 0 && <li className="p-6 text-center text-sm text-muted-foreground">Nothing this month</li>}
        {agenda.map((d) => <li key={d} className="p-3"><p className={cn('mb-1.5 text-xs font-medium', d === today ? 'text-primary' : 'text-muted-foreground')}>{format(parseISO(d), 'EEE, dd MMM')}</p>
          <div className="space-y-1">{byDay.get(d)!.map(chip)}</div></li>)}
      </ul>
    </div>
  )
}
