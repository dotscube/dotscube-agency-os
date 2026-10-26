import type { ReactNode } from 'react'
import { ArrowDown, ArrowUp, ChevronLeft, ChevronRight, Search } from 'lucide-react'
import { useSearchParams } from 'react-router-dom'
import { Button, EmptyState, ErrorState, Input, Skeleton } from '@/components/ui'
import { cn } from '@/lib/utils'

export interface Column<T> {
  key: string
  header: string
  render: (row: T) => ReactNode
  /** database column used for server-side sorting */
  sortKey?: string
  className?: string
}

export interface SortState { column: string; ascending: boolean }

/** Table state lives in the URL so filtered views (e.g. from dashboard cards) are linkable. */
export function useTableState(defaults: { sort?: SortState; pageSize?: number } = {}) {
  const [params, setParams] = useSearchParams()
  const page = Math.max(1, Number(params.get('page') ?? 1) || 1)
  const search = params.get('q') ?? ''
  const sortParam = params.get('sort')
  const sort: SortState | undefined = sortParam
    ? { column: sortParam.replace(/^-/, ''), ascending: !sortParam.startsWith('-') }
    : defaults.sort
  const update = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params)
    for (const [k, v] of Object.entries(patch)) { if (v == null || v === '') next.delete(k); else next.set(k, v) }
    setParams(next, { replace: true })
  }
  return {
    page, search, sort, pageSize: defaults.pageSize ?? 20, params,
    setPage: (p: number) => update({ page: String(p) }),
    setSearch: (q: string) => update({ q, page: null }),
    setSort: (s: SortState) => update({ sort: (s.ascending ? '' : '-') + s.column, page: null }),
    setFilter: (key: string, value: string | null) => update({ [key]: value, page: null }),
  }
}

export function SearchBox({ value, onChange, placeholder = 'Search…' }: { value: string; onChange: (v: string) => void; placeholder?: string }) {
  return (
    <div className="relative w-full sm:w-64">
      <Search className="pointer-events-none absolute left-2.5 top-2.5 size-4 text-muted-foreground" aria-hidden />
      <Input type="search" aria-label={placeholder} placeholder={placeholder} defaultValue={value} className="pl-8"
        onKeyDown={(e) => { if (e.key === 'Enter') onChange((e.target as HTMLInputElement).value) }}
        onBlur={(e) => { if (e.target.value !== value) onChange(e.target.value) }} />
    </div>
  )
}

export function DataTable<T extends object>({
  columns, rows, loading, error, onRetry, total, page, pageSize, onPageChange, sort, onSortChange, onRowClick, empty, rowKey,
}: {
  columns: Column<T>[]; rows: T[] | undefined; loading?: boolean; error?: string | null; onRetry?: () => void
  total?: number; page?: number; pageSize?: number; onPageChange?: (p: number) => void
  sort?: SortState; onSortChange?: (s: SortState) => void; onRowClick?: (row: T) => void; empty?: ReactNode
  rowKey?: (row: T) => string
}) {
  if (error) return <ErrorState message={error} onRetry={onRetry} />
  const pages = total != null && pageSize ? Math.max(1, Math.ceil(total / pageSize)) : 1
  return (
    <div>
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-muted/40 text-left">
              {columns.map((c) => {
                const active = sort && c.sortKey && sort.column === c.sortKey
                return (
                  <th key={c.key} scope="col" className={cn('whitespace-nowrap px-4 py-2.5 font-medium text-muted-foreground', c.className)}
                    aria-sort={active ? (sort!.ascending ? 'ascending' : 'descending') : undefined}>
                    {c.sortKey && onSortChange ? (
                      <button className="inline-flex items-center gap-1 hover:text-foreground"
                        onClick={() => onSortChange({ column: c.sortKey!, ascending: active ? !sort!.ascending : true })}>
                        {c.header}{active && (sort!.ascending ? <ArrowUp className="size-3" /> : <ArrowDown className="size-3" />)}
                      </button>
                    ) : c.header}
                  </th>
                )
              })}
            </tr>
          </thead>
          <tbody>
            {loading && !rows ? Array.from({ length: 5 }).map((_, i) => (
              <tr key={i} className="border-b">{columns.map((c) => <td key={c.key} className="px-4 py-3"><Skeleton className="h-4 w-full max-w-[160px]" /></td>)}</tr>
            )) : rows?.map((row, i) => (
              <tr key={rowKey ? rowKey(row) : (row as { id?: string }).id ?? i}
                className={cn('border-b last:border-0', onRowClick && 'cursor-pointer hover:bg-muted/40')}
                onClick={onRowClick ? () => onRowClick(row) : undefined}
                onKeyDown={onRowClick ? (e) => { if (e.key === 'Enter') onRowClick(row) } : undefined}
                tabIndex={onRowClick ? 0 : undefined}>
                {columns.map((c) => <td key={c.key} className={cn('px-4 py-3 align-middle', c.className)}>{c.render(row)}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {!loading && rows?.length === 0 && (empty ?? <EmptyState title="Nothing here yet" />)}
      {onPageChange && total != null && total > (pageSize ?? 0) && (
        <div className="flex items-center justify-between border-t px-4 py-3 text-sm text-muted-foreground">
          <span>{total} records · page {page} of {pages}</span>
          <div className="flex gap-1">
            <Button variant="outline" size="icon" aria-label="Previous page" disabled={(page ?? 1) <= 1} onClick={() => onPageChange((page ?? 1) - 1)}><ChevronLeft /></Button>
            <Button variant="outline" size="icon" aria-label="Next page" disabled={(page ?? 1) >= pages} onClick={() => onPageChange((page ?? 1) + 1)}><ChevronRight /></Button>
          </div>
        </div>
      )}
    </div>
  )
}
