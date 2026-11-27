import { describe, it, expect, vi, beforeEach } from 'vitest';

// findOrCreateCustomer looks a patient up by the E.164 phone. Since migration-019 a family shares one phone, so several rows can match:
// it must pick the member by name (else the family contact), never rename a family member, and treat raw and +977 forms of one number alike.
const calls = [];
let queue = [];
const builder = (table) => {
  const b = {
    _t: table, _ops: [],
    select(...a) { this._ops.push(['select', ...a]); return this; },
    eq(...a) { this._ops.push(['eq', ...a]); return this; },
    limit(...a) { this._ops.push(['limit', ...a]); return this; },
    update(v) { this._ops.push(['update', v]); return this; },
    insert(v) { this._ops.push(['insert', v]); return this; },
    maybeSingle() { calls.push(this); return Promise.resolve(queue.shift() ?? { data: null, error: null }); },
    single() { calls.push(this); return Promise.resolve(queue.shift() ?? { data: null, error: null }); },
    then(res, rej) { calls.push(this); return Promise.resolve(queue.shift() ?? { data: null, error: null }).then(res, rej); },
  };
  return b;
};
vi.mock('lib/supabase', () => ({ supabase: { from: (t) => builder(t), rpc: vi.fn() }, supabaseCustomer: {}, supabasePlatform: {} }));
vi.mock('lib/analytics', () => ({ capture: vi.fn(), identify: vi.fn(), reset: vi.fn(), setGroup: vi.fn() }));

const { findOrCreateCustomer } = await import('./api');
const phoneEq = () => calls.find((c) => c._t === 'customers')._ops.find((o) => o[0] === 'eq' && o[1] === 'phone')[2];
const updates = () => calls.filter((c) => c._ops.some((o) => o[0] === 'update')).map((c) => c._ops.find((o) => o[0] === 'update')[1]);

beforeEach(() => { calls.length = 0; queue = []; vi.spyOn(console, 'error').mockImplementation(() => {}); });
const base = { orgId: 'o1', branchId: 'b1', phone: '9802000001' };

describe('findOrCreateCustomer with a shared family phone', () => {
  it('raw 98XXXXXXXX and +977-98XXXXXXXX are looked up as the same E.164 number', async () => {
    queue = [{ data: [{ id: 'p', full_name: 'Sita Rai', family_id: null }], error: null}, { data: null, error: null }];
    await findOrCreateCustomer({ ...base, fullName: 'Sita Rai' });
    const a = phoneEq();
    calls.length = 0; queue = [{ data: [{ id: 'p', full_name: 'Sita Rai', family_id: null }], error: null }, { data: null, error: null }];
    await findOrCreateCustomer({ ...base, phone: '+977 9802000001', fullName: 'Sita Rai' });
    expect(phoneEq()).toBe(a);
    expect(a).toBe('+9779802000001');
  });

  it('picks the member whose name matches (case and spaces ignored)', async () => {
    queue = [{ data: [{ id: 'parent', full_name: 'Hari Rai', family_id: 'f1' }, { id: 'child', full_name: 'Sita Rai', family_id: 'f1' }], error: null }, { data: null, error: null }];
    const r = await findOrCreateCustomer({ ...base, fullName: '  sita   RAI ' });
    expect(r.data).toEqual({ customerId: 'child', isNew: false });
  });

  it('with an unknown name returns the family contact and does NOT rename them', async () => {
    queue = [
      { data: [{ id: 'child', full_name: 'Sita Rai', family_id: 'f1' }, { id: 'parent', full_name: 'Hari Rai', family_id: 'f1' }], error: null },
      { data: { contact_customer_id: 'parent' }, error: null },
      { data: null, error: null },
    ];
    const r = await findOrCreateCustomer({ ...base, fullName: 'Somebody New' });
    expect(r.data).toEqual({ customerId: 'parent', isNew: false });
    expect(updates()[0].full_name).toBe('Hari Rai');
  });

  it('a single patient with no family is still refreshed with the typed name (unchanged behaviour)', async () => {
    queue = [{ data: [{ id: 'p', full_name: 'Sita Rai', family_id: null }], error: null }, { data: null, error: null }];
    await findOrCreateCustomer({ ...base, fullName: 'Sita Rai Sharma' });
    expect(updates()[0].full_name).toBe('Sita Rai Sharma');
  });

  it('creates a patient when nobody has the phone', async () => {
    queue = [{ data: [], error: null }, { data: { id: 'new' }, error: null }];
    const r = await findOrCreateCustomer({ ...base, fullName: 'New Person' });
    expect(r.data).toEqual({ customerId: 'new', isNew: true });
  });
});
