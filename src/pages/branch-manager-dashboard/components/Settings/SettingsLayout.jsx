import React, { useEffect, useMemo } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useAuth } from '../../../../contexts/AuthContext';
import { useBranch } from '../../../../contexts/BranchContext';
import { useIndustry } from '../../../../hooks/useIndustry';
import AreaLayout, { AreaPage } from '../Area/AreaLayout';
import { SETTINGS_CATEGORIES, getSettingByView, canOpenSetting, getVisibleSettings } from './settingsRegistry';

// Settings area: the same internal-menu pattern as Reports, without favourites or a catalogue.
// `?view=settings` (and the retired `infrastructure`) land on the first visible page for the role / branch.
const SettingsLayout = ({ view, renderSetting }) => {
  const [, setParams] = useSearchParams();
  const navigate = useNavigate();
  const { profile } = useAuth();
  const { isOverall } = useBranch();
  const { locationLabelPlural, enableChairs } = useIndustry();
  const role = profile?.role;

  const withLabels = (s) => (s.location ? { ...s, title: locationLabelPlural || s.title } : s);
  const visible = useMemo(
    () => getVisibleSettings({ role, isOverall, enableChairs }).map(withLabels),
    [role, isOverall, enableChairs, locationLabelPlural] // eslint-disable-line react-hooks/exhaustive-deps
  );
  const cats = SETTINGS_CATEGORIES.map((c) => ({ ...c, items: visible.filter((s) => s.category === c.id) })).filter((c) => c.items.length);

  const landing = view === 'settings' || view === 'infrastructure';
  const first = visible[0];
  useEffect(() => {
    if (landing && first) navigate(`?view=${first.view}`, { replace: true });
  }, [landing, first?.view]); // eslint-disable-line react-hooks/exhaustive-deps

  const item = landing ? null : getSettingByView(view);
  const shown = item && withLabels(item);
  const allowed = canOpenSetting(item, role, isOverall);

  return (
    <AreaLayout title="Settings" menuStorageKey="clinicmd.settings.menu" categories={cats} activeView={view} onNavigate={(v) => setParams({ view: v })}>
      {({ reopen }) => (shown ? (
        <AreaPage title={shown.title} description={shown.description} backLabel="Settings" onBack={() => first && setParams({ view: first.view })} reopen={reopen}>
          {allowed ? renderSetting(shown.view) : (
            <p className="py-12 text-center text-sm text-text-secondary">This page isn't available here.</p>
          )}
        </AreaPage>
      ) : null)}
    </AreaLayout>
  );
};

export default SettingsLayout;
