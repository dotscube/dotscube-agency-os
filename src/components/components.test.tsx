import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { DataTable } from './DataTable'
import { ErrorState, Field, Input, StatusBadge } from './ui'

const cols = [{ key: 'n', header: 'Name', sortKey: 'name', render: (r: { id: string; name: string }) => r.name }]

describe('DataTable', () => {
  it('renders rows and handles row clicks', () => {
    const onRowClick = vi.fn()
    render(<MemoryRouter><DataTable columns={cols} rows={[{ id: '1', name: 'Maahaul India' }]} onRowClick={onRowClick} /></MemoryRouter>)
    fireEvent.click(screen.getByText('Maahaul India'))
    expect(onRowClick).toHaveBeenCalledWith({ id: '1', name: 'Maahaul India' })
  })
  it('shows an empty state', () => {
    render(<DataTable columns={cols} rows={[]} />)
    expect(screen.getByText('Nothing here yet')).toBeInTheDocument()
  })
  it('shows an error state with retry', () => {
    const retry = vi.fn()
    render(<DataTable columns={cols} rows={undefined} error="You don't have permission to do that." onRetry={retry} />)
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(retry).toHaveBeenCalled()
  })
  it('toggles sorting and exposes aria-sort', () => {
    const onSort = vi.fn()
    render(<DataTable columns={cols} rows={[]} sort={{ column: 'name', ascending: true }} onSortChange={onSort} />)
    expect(screen.getByRole('columnheader')).toHaveAttribute('aria-sort', 'ascending')
    fireEvent.click(screen.getByRole('button', { name: /Name/ }))
    expect(onSort).toHaveBeenCalledWith({ column: 'name', ascending: false })
  })
  it('paginates', () => {
    const onPage = vi.fn()
    render(<DataTable columns={cols} rows={[{ id: '1', name: 'a' }]} total={45} page={1} pageSize={20} onPageChange={onPage} />)
    expect(screen.getByText(/page 1 of 3/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Previous page' })).toBeDisabled()
    fireEvent.click(screen.getByRole('button', { name: 'Next page' }))
    expect(onPage).toHaveBeenCalledWith(2)
  })
})

describe('ui', () => {
  it('links field label, control and error for screen readers', () => {
    render(<Field label="Work email" error="Enter a valid email">{(p) => <Input {...p} />}</Field>)
    const input = screen.getByLabelText('Work email')
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(input).toHaveAccessibleDescription('Enter a valid email')
  })
  it('renders status badges and alert role', () => {
    render(<><StatusBadge value="notice_period" /><ErrorState message="Boom" /></>)
    expect(screen.getByText('Notice Period')).toBeInTheDocument()
    expect(screen.getByRole('alert')).toHaveTextContent('Boom')
  })
})
