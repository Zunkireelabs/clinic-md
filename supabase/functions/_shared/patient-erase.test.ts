import { describe, it, expect, vi } from 'vitest';
import { runPatientErase, type EraseDeps, type ActionResult } from './patient-erase';

const input = { customerId: 'c1', requestPath: 'o/c1/req.pdf', typedName: 'A B' };
const ok = (data: unknown = { customer_id: 'c1', label: 'Erased patient P-00001', auth_user_ids: [] }): ActionResult => ({ ok: true, action_id: 'a1', data, error: null });
const refuse = (code: string): ActionResult => ({ ok: false, action_id: 'a0', data: null, error: { code, message: code } });

const make = (rpcs: Array<{ data: ActionResult | null; error: { message: string } | null }>, over: Partial<EraseDeps> = {}) => {
  const queue = [...rpcs];
  const deps: EraseDeps = {
    eraseRpc: vi.fn(async () => queue.shift() ?? { data: null, error: { message: 'no more' } }),
    listAudioPaths: vi.fn(async () => ['o/b1/r1.webm', 'o/b1/r2.webm']),
    removeAudio: vi.fn(async (p: string[]) => ({ removed: p, error: null })),
    deleteAuthUser: vi.fn(async () => true),
    log: vi.fn(),
    ...over,
  };
  return deps;
};

describe('runPatientErase', () => {
  it('rejects missing input without touching anything', async () => {
    const deps = make([]);
    const r = await runPatientErase(deps, { customerId: '', requestPath: '', typedName: '' });
    expect(r.status).toBe(400);
    expect(deps.eraseRpc).not.toHaveBeenCalled();
  });

  it('erases in one call when there are no recordings, and deletes no files', async () => {
    const deps = make([{ data: ok(), error: null }]);
    const r = await runPatientErase(deps, input);
    expect(r.status).toBe(200);
    expect(deps.removeAudio).not.toHaveBeenCalled();
    expect(r.body.data).toMatchObject({ deleted_recordings: 0, logins_removed: 0 });
    expect(r.body.data.auth_user_ids).toBeUndefined();
  });

  it.each(['FORBIDDEN', 'REQUEST_FILE_MISSING', 'NAME_MISMATCH', 'PATIENT_NOT_FOUND', 'ALREADY_ERASED'])('%s: returns the refusal and deletes NOTHING', async (code) => {
    const deps = make([{ data: refuse(code), error: null }]);
    const r = await runPatientErase(deps, input);
    expect(r.body.error?.code).toBe(code);
    expect(r.status).toBe(code === 'FORBIDDEN' ? 403 : 409);
    expect(deps.listAudioPaths).not.toHaveBeenCalled();
    expect(deps.removeAudio).not.toHaveBeenCalled();
    expect(deps.eraseRpc).toHaveBeenCalledTimes(1);
  });

  it('AUDIO_FILES_REMAIN: deletes the recordings, then runs the database step again', async () => {
    const deps = make([{ data: refuse('AUDIO_FILES_REMAIN'), error: null }, { data: ok(), error: null }]);
    const r = await runPatientErase(deps, input);
    expect(deps.removeAudio).toHaveBeenCalledWith(['o/b1/r1.webm', 'o/b1/r2.webm']);
    expect(deps.eraseRpc).toHaveBeenCalledTimes(2);
    expect(r.status).toBe(200);
    expect(r.body.data.deleted_recordings).toBe(2);
  });

  it('a partial delete stops before the database step and says the patient was NOT erased', async () => {
    const deps = make([{ data: refuse('AUDIO_FILES_REMAIN'), error: null }], { removeAudio: vi.fn(async () => ({ removed: ['o/b1/r1.webm'], error: 'boom' })) });
    const r = await runPatientErase(deps, input);
    expect(r.status).toBe(502);
    expect(r.body.error?.code).toBe('AUDIO_DELETE_FAILED');
    expect(deps.eraseRpc).toHaveBeenCalledTimes(1);
    expect(deps.log).toHaveBeenCalledWith('error', expect.stringContaining('nothing was erased'), expect.objectContaining({ deleted: ['o/b1/r1.webm'], left: ['o/b1/r2.webm'] }));
  });

  it('files deleted but the database step fails: an error, and the deleted files are logged', async () => {
    const deps = make([{ data: refuse('AUDIO_FILES_REMAIN'), error: null }, { data: null, error: { message: 'db down' } }]);
    const r = await runPatientErase(deps, input);
    expect(r.status).toBe(500);
    expect(r.body.error?.code).toBe('ERASE_INCOMPLETE');
    expect(deps.log).toHaveBeenCalledWith('error', expect.stringContaining('recordings are gone'), expect.objectContaining({ deleted: ['o/b1/r1.webm', 'o/b1/r2.webm'], error: 'db down' }));
  });

  it('files deleted but the database refuses the second time: the refusal comes back with the count', async () => {
    const deps = make([{ data: refuse('AUDIO_FILES_REMAIN'), error: null }, { data: refuse('AUDIO_FILES_REMAIN'), error: null }]);
    const r = await runPatientErase(deps, input);
    expect(r.status).toBe(409);
    expect(r.body.data).toMatchObject({ deleted_recordings: 2 });
  });

  it('removes the patient login after a successful erase; a failing login delete does not undo the erase', async () => {
    const deps = make([{ data: ok({ customer_id: 'c1', auth_user_ids: ['u1', 'u2'] }), error: null }], {
      deleteAuthUser: vi.fn(async (id: string) => { if (id === 'u2') throw new Error('nope'); return true; }),
    });
    const r = await runPatientErase(deps, input);
    expect(r.status).toBe(200);
    expect(r.body.data.logins_removed).toBe(1);
    expect(deps.log).toHaveBeenCalledWith('error', expect.stringContaining('login not removed'), expect.objectContaining({ authUser: 'u2' }));
  });

  it('a transport error on the first call is a failure, nothing deleted', async () => {
    const deps = make([{ data: null, error: { message: 'network' } }]);
    const r = await runPatientErase(deps, input);
    expect(r.status).toBe(500);
    expect(deps.removeAudio).not.toHaveBeenCalled();
  });
});
