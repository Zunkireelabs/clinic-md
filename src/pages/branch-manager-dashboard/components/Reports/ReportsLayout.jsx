import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import Icon from '../../../../components/AppIcon';
import { useAuth } from '../../../../contexts/AuthContext';
import { useBranch } from '../../../../contexts/BranchContext';
import { useTransferFeature } from '../../../../hooks/useTransferFeature';
import { REPORT_CATEGORIES, getReportByView, canOpenReport, getVisibleReports } from './reportRegistry';

const MENU_KEY = 'clinicmd.reports.menu';
const favKey = (userId) => `clinicmd.reports.favs.${userId || 'anon'}`;

const readJSON = (key, fallback) => { try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; } };
const writeJSON = (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* storage unavailable */ } };

const Star = ({ on, onToggle, label, className = '' }) => (
  <button
    type="button"
    onClick={(e) => { e.stopPropagation(); onToggle(); }}
    aria-pressed={on}
    aria-label={on ? `Remove ${label} from favourites` : `Add ${label} to favourites`}
    title={on ? 'Remove from favourites' : 'Add to favourites'}
    className={`p-1.5 rounded-spa hover:bg-black/[0.05] spa-transition-fast ${on ? 'text-warning' : 'text-text-tertiary hover:text-text-secondary'} ${className}`}
  >
    <Icon name="Star" size={16} fill={on ? 'currentColor' : 'none'} />
  </button>
);

// Reports area: an internal menu (lg+), a searchable catalogue with favourites, and a slim header over each report panel.
// `renderReport(view)` returns the (unchanged) panel for a registry view.
const ReportsLayout = ({ view, renderReport }) => {
  const [params, setParams] = useSearchParams();
  const { profile } = useAuth();
  const { branchName, isOverall } = useBranch();
  const transfersAvailable = useTransferFeature();
  const role = profile?.role;
  const userId = profile?.id;

  const [menuOpen, setMenuOpen] = useState(() => { try { return localStorage.getItem(MENU_KEY) !== 'collapsed'; } catch { return true; } });
  const toggleMenu = () => setMenuOpen((o) => { try { localStorage.setItem(MENU_KEY, o ? 'collapsed' : 'open'); } catch { /* ignore */ } return !o; });

  const [favs, setFavs] = useState(() => readJSON(favKey(userId), []));
  useEffect(() => { setFavs(readJSON(favKey(userId), [])); }, [userId]);
  const toggleFav = useCallback((id) => {
    setFavs((prev) => { const next = prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]; writeJSON(favKey(userId), next); return next; });
  }, [userId]);

  const [query, setQuery] = useState('');
  const visible = useMemo(() => getVisibleReports(role, transfersAvailable), [role, transfersAvailable]);
  const favCount = visible.filter((r) => favs.includes(r.id)).length;
  const tab = params.get('tab');
  const go = (v, extra = {}) => setParams({ view: v, ...extra });
  const openCatalogue = () => go('all-reports');

  const report = view === 'all-reports' ? null : getReportByView(view);
  const scope = isOverall ? 'all branches' : (branchName || 'this branch');
  const cats = REPORT_CATEGORIES.map((c) => ({ ...c, items: visible.filter((r) => r.category === c.id) })).filter((c) => c.items.length);

  const reopen = !menuOpen && (
    <button type="button" onClick={toggleMenu} aria-label="Show reports menu" title="Show reports menu" className="hidden lg:inline-flex p-1.5 -ml-1.5 rounded-spa hover:bg-black/[0.05] text-text-secondary">
      <Icon name="PanelLeftOpen" size={16} />
    </button>
  );

  // ── Internal menu ──
  const row = (active) => `w-full h-8 flex items-center gap-2.5 px-2.5 rounded-spa text-[13px] text-left spa-transition-fast ${
    active ? 'bg-white shadow-[0_0_0_1px_#E9E9EC] text-text-primary font-medium' : 'text-text-secondary hover:bg-black/[0.04]'
  }`;
  const menu = menuOpen && (
    <aside className="hidden lg:flex w-[232px] flex-shrink-0 flex-col border-r border-border bg-background">
      <div className="h-11 px-3 flex items-center justify-between flex-shrink-0">
        <span className="text-[13px] font-semibold text-text-primary px-0.5">Reports</span>
        <button type="button" onClick={toggleMenu} aria-label="Hide reports menu" title="Hide reports menu" className="p-1.5 rounded-spa hover:bg-black/[0.05] text-text-tertiary hover:text-text-secondary">
          <Icon name="PanelLeftClose" size={16} />
        </button>
      </div>
      <nav className="sidebar-scroll flex-1 overflow-y-auto px-3 pb-4" aria-label="Reports">
        <button type="button" className={row(view === 'all-reports' && tab !== 'favourites')} onClick={openCatalogue}>
          <Icon name="LayoutList" size={15} className="flex-shrink-0" />
          <span className="flex-1">All reports</span>
          <span className="text-[11px] text-text-tertiary tabular-nums">{visible.length}</span>
        </button>
        <button type="button" className={`${row(view === 'all-reports' && tab === 'favourites')} mt-0.5`} onClick={() => go('all-reports', { tab: 'favourites' })}>
          <Icon name="Star" size={15} className="flex-shrink-0" />
          <span className="flex-1">Favourites</span>
          <span className="text-[11px] text-text-tertiary tabular-nums">{favCount}</span>
        </button>
        <div className="h-px bg-border my-3" />
        {cats.map((c) => (
          <div key={c.id} className="mb-3">
            <p className="px-2.5 mb-1 text-[11px] font-medium uppercase tracking-wide text-text-tertiary">{c.label}</p>
            {c.items.map((r) => (
              <button key={r.id} type="button" className={`${row(view === r.view)} mb-0.5`} onClick={() => go(r.view)} aria-current={view === r.view ? 'page' : undefined}>
                <Icon name={r.icon} size={15} className="flex-shrink-0" />
                <span className="flex-1 truncate">{r.title}</span>
              </button>
            ))}
          </div>
        ))}
      </nav>
    </aside>
  );

  // ── Catalogue ──
  const renderCatalogue = () => {
    const q = query.trim().toLowerCase();
    const base = tab === 'favourites' ? visible.filter((r) => favs.includes(r.id)) : visible;
    const matches = q ? base.filter((r) => `${r.title} ${r.description}`.toLowerCase().includes(q)) : base;
    const groups = REPORT_CATEGORIES.map((c) => ({ ...c, items: matches.filter((r) => r.category === c.id) })).filter((c) => c.items.length);
    return (
      <>
        <div className="px-4 sm:px-6 lg:px-8 pt-5 pb-4 border-b border-border flex-shrink-0">
          <div className="flex items-center gap-2">
            {reopen}
            <h1 className="font-heading font-heading-semibold text-xl text-text-primary">{tab === 'favourites' ? 'Favourites' : 'All reports'}</h1>
            <span className="px-2 py-0.5 rounded-full bg-black/[0.05] text-[11px] font-medium text-text-secondary tabular-nums">{base.length}</span>
          </div>
          <p className="mt-1 text-[13px] text-text-secondary">{tab === 'favourites' ? 'Your starred reports.' : `Every report for ${scope}.`}</p>
          <div className="relative mt-4 max-w-md">
            <Icon name="Search" size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-text-tertiary pointer-events-none" />
            <input
              type="text"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search reports"
              aria-label="Search reports"
              className="w-full h-9 pl-9 pr-3 rounded-spa-lg border border-border bg-surface text-sm text-text-primary placeholder:text-text-tertiary focus:outline-none focus:ring-2 focus:ring-primary/30"
            />
          </div>
        </div>
        <div className="content-scroll flex-1 min-h-0 overflow-y-auto px-4 sm:px-6 lg:px-8 py-5">
          {matches.length === 0 ? (
            <p className="py-12 text-center text-sm text-text-secondary">
              {q ? `No reports match “${query.trim()}”.` : 'Star a report to pin it here.'}
            </p>
          ) : groups.map((g) => (
            <section key={g.id} className="mb-6">
              <h2 className="mb-2 text-[11px] font-medium uppercase tracking-wide text-text-tertiary">{g.label}</h2>
              <div className="border border-border rounded-spa-lg divide-y divide-border overflow-hidden bg-surface">
                {g.items.map((r) => (
                  <div
                    key={r.id}
                    role="button"
                    tabIndex={0}
                    onClick={() => go(r.view)}
                    onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(r.view); } }}
                    className="flex items-center gap-3 px-4 py-3 cursor-pointer hover:bg-black/[0.02] focus:outline-none focus-visible:bg-black/[0.03]"
                  >
                    <span className="w-10 h-10 rounded-spa-lg bg-primary/10 text-primary flex items-center justify-center flex-shrink-0">
                      <Icon name={r.icon} size={18} />
                    </span>
                    <span className="flex-1 min-w-0">
                      <span className="block text-sm font-medium text-text-primary">{r.title}</span>
                      <span className="block text-[13px] text-text-secondary">{r.description}</span>
                    </span>
                    <Star on={favs.includes(r.id)} onToggle={() => toggleFav(r.id)} label={r.title} />
                  </div>
                ))}
              </div>
            </section>
          ))}
        </div>
      </>
    );
  };

  // ── A report ──
  const renderReportPage = () => {
    const allowed = canOpenReport(report, role);
    return (
      <>
        <div className="px-4 sm:px-6 lg:px-8 pt-3 pb-3 border-b border-border flex-shrink-0">
          <button type="button" onClick={openCatalogue} className="lg:hidden mb-2 inline-flex items-center gap-1 text-[13px] text-text-secondary hover:text-text-primary">
            <Icon name="ChevronLeft" size={14} /> Reports
          </button>
          <div className="flex items-center gap-2">
            {reopen}
            <h1 className="font-heading font-heading-semibold text-lg text-text-primary">{report.title}</h1>
            <Star on={favs.includes(report.id)} onToggle={() => toggleFav(report.id)} label={report.title} />
          </div>
          <p className="text-[13px] text-text-secondary">{report.description}</p>
        </div>
        <div className="content-scroll flex-1 min-h-0 overflow-y-auto px-3 sm:px-4 md:px-6 lg:px-8 py-3 sm:py-4">
          {allowed ? renderReport(report.view) : (
            <p className="py-12 text-center text-sm text-text-secondary">This report isn't available for your role.</p>
          )}
        </div>
      </>
    );
  };

  return (
    <div className="h-full flex min-h-0">
      {menu}
      <div className="flex-1 min-w-0 min-h-0 flex flex-col">
        {report ? renderReportPage() : renderCatalogue()}
      </div>
    </div>
  );
};

export default ReportsLayout;
