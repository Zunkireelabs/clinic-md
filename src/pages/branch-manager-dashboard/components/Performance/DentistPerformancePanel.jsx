import React, { useState, useEffect, useCallback, useMemo } from 'react';
import Icon from '../../../../components/AppIcon';
import FilterBar from '../../../../components/ui/FilterBar';
import { PERIOD_PRESETS, getPeriodRange, getTodayISO } from '../../../../utils/periodPresets';
import { getDentistPerformance } from '../../../../services/api';
import DentistDetailView from './DentistDetailView';

function getTier(score) {
  if (score >= 85) return { label: 'Top Performer', color: 'bg-success/10 text-success' };
  if (score >= 70) return { label: 'Strong', color: 'bg-primary/10 text-primary' };
  if (score >= 55) return { label: 'Average', color: 'bg-warning/10 text-warning' };
  return { label: 'Needs Attention', color: 'bg-error/10 text-error' };
}

function ScoreBadge({ score }) {
  const tier = getTier(score);
  return (
    <div className="flex items-center space-x-2">
      <span className="font-data font-data-medium text-sm text-text-primary">{score}</span>
      <span className={`inline-flex items-center px-2 py-0.5 rounded font-caption font-caption-medium text-[11px] ${tier.color}`}>
        {tier.label}
      </span>
    </div>
  );
}

function formatHours(h) {
  return `${Number(h || 0).toLocaleString('en-IN', { maximumFractionDigits: 1 })}h`;
}

const DentistPerformancePanel = ({ branchId }) => {
  const today = getTodayISO();

  const [activePreset, setActivePreset] = useState('monthly');
  const [mode, setMode] = useState('preset'); // 'preset' | 'custom'
  const [customFrom, setCustomFrom] = useState('');   // live input value
  const [customTo, setCustomTo] = useState('');       // live input value
  const [appliedFrom, setAppliedFrom] = useState(''); // committed on Apply
  const [appliedTo, setAppliedTo] = useState('');     // committed on Apply
  const [searchQuery, setSearchQuery] = useState('');
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [selectedDentist, setSelectedDentist] = useState(null); // { id, name } | null

  // Range is driven by APPLIED dates so editing the pickers doesn't re-fetch
  // until the user clicks Apply.
  const range = useMemo(() => {
    if (mode === 'custom' && appliedFrom) {
      return { fromDate: appliedFrom, toDate: appliedTo || today };
    }
    const { startDate, endDate } = getPeriodRange(activePreset);
    return { fromDate: startDate, toDate: endDate };
  }, [mode, activePreset, appliedFrom, appliedTo, today]);

  // True when the inputs differ from what's currently applied (pending Apply).
  const customDirty = customFrom && (customFrom !== appliedFrom || customTo !== appliedTo);

  const loadData = useCallback(async () => {
    if (!branchId) return;
    setLoading(true);
    setError(null);

    const result = await getDentistPerformance({ branchId, ...range });

    if (result.error) {
      setError(result.error.message || 'Failed to load performance data.');
      setLoading(false);
      return;
    }

    setData(result.data);
    setLoading(false);
  }, [branchId, range]);

  useEffect(() => { loadData(); }, [loadData]);

  const handlePreset = (id) => {
    setMode('preset');
    setActivePreset(id);
  };

  const handleCustomApply = () => {
    if (!customFrom) return;
    setAppliedFrom(customFrom);
    setAppliedTo(customTo);
    setMode('custom');
  };

  const visibleDentists = useMemo(() => {
    const all = data?.dentists || [];
    const q = searchQuery.trim().toLowerCase();
    if (!q) return all;
    return all.filter((t) => (t.dentistName || '').toLowerCase().includes(q));
  }, [data, searchQuery]);

  const handleExportCSV = () => {
    const rows = visibleDentists;
    if (!rows.length) return;
    const esc = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;
    const header = ['Rank', 'Dentist', 'Score', 'Tier', 'Treatments', 'Customers', 'Worked (h)', 'Occupied (h)', 'Utilization %'];
    let csv = header.join(',') + '\n';
    rows.forEach((t, idx) => {
      csv += [
        idx + 1,
        esc(t.dentistName),
        t.performanceScore,
        esc(getTier(t.performanceScore).label),
        t.treatmentsCompleted,
        t.customersAttended,
        t.workedHours,
        t.occupiedHours,
        t.utilizationRate,
      ].join(',') + '\n';
    });
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `performance-report-${data?.periodStart || ''}-to-${data?.periodEnd || ''}.csv`;
    link.click();
    URL.revokeObjectURL(url);
  };

  // ── Drill-down: dentist detail view replaces this whole panel ──────────
  if (selectedDentist) {
    return (
      <DentistDetailView
        dentistId={selectedDentist.id}
        dentistName={selectedDentist.name}
        branchId={branchId}
        onBack={() => setSelectedDentist(null)}
      />
    );
  }

  // ── Loading ────────────────────────────────────────────────
  if (loading) {
    return (
      <div className="space-y-4">
        <div className="bg-surface rounded-spa-lg border border-border p-6 animate-pulse">
          <div className="h-5 bg-background rounded w-48 mb-4" />
          <div className="space-y-3">
            {[0, 1, 2, 3].map(i => (
              <div key={i} className="h-12 bg-background rounded" />
            ))}
          </div>
        </div>
      </div>
    );
  }

  // ── Error ──────────────────────────────────────────────────
  if (error) {
    return (
      <div className="bg-error/5 border border-error/20 rounded-spa p-4 flex items-center space-x-3">
        <Icon name="AlertCircle" size={18} className="text-error flex-shrink-0" />
        <p className="font-body text-sm text-error">{error}</p>
        <button onClick={loadData} className="ml-auto font-body font-body-medium text-sm text-error underline">
          Retry
        </button>
      </div>
    );
  }

  const dentists = visibleDentists;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-body text-sm text-text-secondary">
            Ranked by weighted performance score. Click a dentist for the full breakdown.
            {data && ` Period: ${data.periodStart} to ${data.periodEnd}`}
          </p>
        </div>
        {dentists.length > 0 && (
          <button
            onClick={handleExportCSV}
            className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-spa border border-border bg-surface font-body font-body-medium text-sm text-text-secondary hover:bg-background spa-transition-fast flex-shrink-0"
          >
            <Icon name="Download" size={16} />
            <span>Export CSV</span>
          </button>
        )}
      </div>

      {/* Filters */}
      <FilterBar
        count={{ value: dentists.length, label: dentists.length === 1 ? 'Dentist' : 'Dentists' }}
        search={{ value: searchQuery, onChange: setSearchQuery, placeholder: 'Search dentist by name…' }}
        presets={PERIOD_PRESETS.map((p) => ({
          label: p.label,
          active: mode === 'preset' && activePreset === p.id,
          onClick: () => handlePreset(p.id),
        }))}
        dateRange={{
          from: customFrom,
          onFromChange: setCustomFrom,
          to: customTo,
          onToChange: setCustomTo,
          max: today,
          onApply: handleCustomApply,
          applyDisabled: !customFrom || !customDirty,
          applyActive: mode === 'custom',
        }}
      />

      {/* Tier Legend */}
      <div className="flex flex-wrap items-center gap-3">
        {[
          { label: 'Top Performer (85+)', color: 'bg-success' },
          { label: 'Strong (70–84)', color: 'bg-primary' },
          { label: 'Average (55–69)', color: 'bg-warning' },
          { label: 'Needs Attention (<55)', color: 'bg-error' },
        ].map(t => (
          <div key={t.label} className="flex items-center space-x-1.5">
            <span className={`w-2.5 h-2.5 rounded-full ${t.color}`} />
            <span className="font-caption font-caption-normal text-[11px] text-text-tertiary">{t.label}</span>
          </div>
        ))}
      </div>

      {/* Table */}
      <div className="bg-surface rounded-spa-lg border border-border overflow-hidden">
        {dentists.length === 0 ? (
          <div className="p-12 text-center">
            <Icon name="Users" size={40} className="text-text-tertiary mx-auto mb-3" />
            <h3 className="font-body font-body-medium text-sm text-text-primary mb-1">No Performance Data</h3>
            <p className="font-body text-xs text-text-tertiary">No active dentists or bookings found for this period.</p>
          </div>
        ) : (
          <>
          <div className="hidden md:block overflow-x-auto">
            <table className="w-full min-w-[720px]">
              <thead>
                <tr className="bg-background/50 border-b border-border">
                  <th className="px-4 py-3 text-left font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide w-12">#</th>
                  <th className="px-4 py-3 text-left font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide">Dentist</th>
                  <th className="px-4 py-3 text-left font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide">Score</th>
                  <th className="px-4 py-3 text-center font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide">Treatments</th>
                  <th className="px-4 py-3 text-center font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide">Customers</th>
                  <th className="px-4 py-3 text-center font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide">Worked</th>
                  <th className="px-4 py-3 text-center font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide">Occupied</th>
                  <th className="px-4 py-3 text-center font-body font-body-medium text-xs text-text-secondary uppercase tracking-wide">Utilization</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {dentists.map((t, idx) => {
                  const rank = idx + 1;
                  return (
                    <tr
                      key={t.dentistId}
                      onClick={() => setSelectedDentist({ id: t.dentistId, name: t.dentistName })}
                      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setSelectedDentist({ id: t.dentistId, name: t.dentistName }); } }}
                      role="button"
                      tabIndex={0}
                      className="hover:bg-background/30 spa-transition-fast cursor-pointer"
                    >
                      {/* Rank */}
                      <td className="px-4 py-3">
                        <span className={`inline-flex items-center justify-center w-7 h-7 rounded-full font-data font-data-medium text-xs ${
                          rank <= 3 ? 'bg-accent/10 text-accent' : 'bg-background text-text-tertiary'
                        }`}>
                          {rank}
                        </span>
                      </td>

                      {/* Dentist */}
                      <td className="px-4 py-3">
                        <div className="flex items-center space-x-2 min-w-0">
                          <div className="w-8 h-8 rounded-full bg-primary/10 flex items-center justify-center flex-shrink-0">
                            <Icon name="User" size={14} className="text-primary" />
                          </div>
                          <span className="font-body font-body-medium text-sm text-text-primary truncate">{t.dentistName}</span>
                          <Icon name="ChevronRight" size={14} className="text-text-tertiary ml-auto flex-shrink-0" />
                        </div>
                      </td>

                      {/* Score */}
                      <td className="px-4 py-3">
                        <ScoreBadge score={t.performanceScore} />
                      </td>

                      {/* Treatments */}
                      <td className="px-4 py-3 text-center">
                        <span className="font-data font-data-normal text-sm text-text-primary">{t.treatmentsCompleted}</span>
                      </td>

                      {/* Customers */}
                      <td className="px-4 py-3 text-center">
                        <span className="font-data font-data-normal text-sm text-text-primary">{t.customersAttended}</span>
                      </td>

                      {/* Worked */}
                      <td className="px-4 py-3 text-center">
                        <span className="font-data font-data-normal text-sm text-text-primary">{formatHours(t.workedHours)}</span>
                      </td>

                      {/* Occupied */}
                      <td className="px-4 py-3 text-center">
                        <span className="font-data font-data-normal text-sm text-text-primary">{formatHours(t.occupiedHours)}</span>
                      </td>

                      {/* Utilization */}
                      <td className="px-4 py-3 text-center">
                        <span className={`font-data font-data-normal text-sm ${
                          t.utilizationRate >= 70 ? 'text-success' : t.utilizationRate >= 40 ? 'text-warning' : 'text-error'
                        }`}>
                          {t.utilizationRate}%
                        </span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          {/* Mobile card stack */}
          <div className="md:hidden divide-y divide-border">
            {dentists.map((t, idx) => {
              const rank = idx + 1;
              return (
                <div
                  key={t.dentistId}
                  onClick={() => setSelectedDentist({ id: t.dentistId, name: t.dentistName })}
                  role="button"
                  tabIndex={0}
                  className="p-4 space-y-3 cursor-pointer active:bg-background/40"
                >
                  <div className="flex items-center justify-between gap-2">
                    <div className="flex items-center gap-2 min-w-0">
                      <span className={`inline-flex items-center justify-center w-7 h-7 rounded-full font-data font-data-medium text-xs flex-shrink-0 ${
                        rank <= 3 ? 'bg-accent/10 text-accent' : 'bg-background text-text-tertiary'
                      }`}>
                        {rank}
                      </span>
                      <div className="w-8 h-8 rounded-full bg-primary/10 flex items-center justify-center flex-shrink-0">
                        <Icon name="User" size={14} className="text-primary" />
                      </div>
                      <span className="font-body font-body-medium text-sm text-text-primary truncate">{t.dentistName}</span>
                      <Icon name="ChevronRight" size={14} className="text-text-tertiary flex-shrink-0" />
                    </div>
                    <ScoreBadge score={t.performanceScore} />
                  </div>

                  <div className="grid grid-cols-2 gap-x-3 gap-y-2 text-sm">
                    <div className="flex justify-between">
                      <span className="text-text-tertiary text-xs">Treatments</span>
                      <span className="font-data font-data-normal text-text-primary">{t.treatmentsCompleted}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-text-tertiary text-xs">Customers</span>
                      <span className="font-data font-data-normal text-text-primary">{t.customersAttended}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-text-tertiary text-xs">Worked</span>
                      <span className="font-data font-data-normal text-text-primary">{formatHours(t.workedHours)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-text-tertiary text-xs">Occupied</span>
                      <span className="font-data font-data-normal text-text-primary">{formatHours(t.occupiedHours)}</span>
                    </div>
                    <div className="flex justify-between col-span-2">
                      <span className="text-text-tertiary text-xs">Utilization</span>
                      <span className={`font-data font-data-normal ${
                        t.utilizationRate >= 70 ? 'text-success' : t.utilizationRate >= 40 ? 'text-warning' : 'text-error'
                      }`}>{t.utilizationRate}%</span>
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
          </>
        )}
      </div>
    </div>
  );
};

export default DentistPerformancePanel;
