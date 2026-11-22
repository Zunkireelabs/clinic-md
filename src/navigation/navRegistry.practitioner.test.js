import { describe, it, expect } from 'vitest';
import { getNav } from './navRegistry';
import { getVisibleReports } from '../pages/branch-manager-dashboard/components/Reports/reportRegistry';
import { getVisibleSettings } from '../pages/branch-manager-dashboard/components/Settings/settingsRegistry';

// CMD-79: the practitioner access level is the limited one. Calendar and Patients only: no Money, Payroll, Settings or Reports.
const ids = (role, opts = {}) => {
  const nav = getNav({ role, isOverall: false, transfersAvailable: true, staffLabelPlural: 'Dentists', ...opts });
  return { main: nav.sections.flatMap((s) => s.items.map((i) => i.id)), footer: nav.footer.map((i) => i.id) };
};

describe('practitioner access level (CMD-79)', () => {
  it('sees Calendar and Patients, nothing else in the sidebar', () => {
    const { main, footer } = ids('practitioner');
    expect(main.sort()).toEqual(['calendar', 'customers']);
    expect(footer).toEqual([]); // no Settings
  });

  it.each(['dashboard', 'reports', 'payroll', 'packages', 'memberships', 'vouchers', 'outreach', 'bookings', 'dentists', 'attendance'])(
    'does not see %s', (id) => {
      const { main, footer } = ids('practitioner');
      expect([...main, ...footer]).not.toContain(id);
    });

  it('has no reports and no settings pages', () => {
    expect(getVisibleReports('practitioner', true)).toEqual([]);
    expect(getVisibleSettings({ role: 'practitioner', isOverall: false, enableChairs: true })).toEqual([]);
  });

  it('does not change what staff, manager and admin see', () => {
    expect(ids('staff').main).toEqual(expect.arrayContaining(['dashboard', 'calendar', 'bookings']));
    expect(ids('staff').main).not.toContain('customers');
    expect(ids('manager').main).toEqual(expect.arrayContaining(['dashboard', 'calendar', 'customers', 'reports']));
    expect(ids('admin').main).toContain('payroll');
    expect(ids('manager').footer).toEqual(['settings']);
  });
});
