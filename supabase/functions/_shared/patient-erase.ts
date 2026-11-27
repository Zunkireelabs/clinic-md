// Erase a patient (CMD-100, migration-019): the recordings live in Storage, and SQL must not delete storage.objects, so this runs the
// two steps in one flow. The database function act_patient_erase is the judge: it checks the role (owner only), the uploaded written
// request, the typed name, and REFUSES (AUDIO_FILES_REMAIN) while any recording still exists. So the order is:
//   1. ask the database. Any refusal other than AUDIO_FILES_REMAIN comes straight back: nothing was deleted.
//   2. AUDIO_FILES_REMAIN means every other check passed: delete the recordings through the Storage API.
//   3. ask the database again. If it fails now, the files are already gone: say so, and log exactly which ones.
//   4. on success, remove the patient's login (auth user) when there was one.
// Pure logic with injected dependencies, so it is unit-tested without a network (patient-erase.test.ts) and run against local Storage
// by scripts/test-patient-erase-local.mjs.

export interface EraseInput { customerId: string; requestPath: string; typedName: string }

export interface ActionResult { ok: boolean; action_id: string | null; data: any; error: { code: string; message: string } | null }

export interface EraseDeps {
  /** Calls act_patient_erase as the CALLER (their JWT), never as the service role. */
  eraseRpc(input: EraseInput): Promise<{ data: ActionResult | null; error: { message: string } | null }>;
  /** Every consultation-audio object of this patient (consultations.audio_paths plus anything under their bookings' folders). */
  listAudioPaths(customerId: string): Promise<string[]>;
  /** Deletes through the Storage API. Returns what was really removed. */
  removeAudio(paths: string[]): Promise<{ removed: string[]; error: string | null }>;
  deleteAuthUser(id: string): Promise<boolean>;
  log(level: 'info' | 'error', message: string, detail?: unknown): void;
}

const failure = (code: string, message: string, data: unknown = null): ActionResult => ({ ok: false, action_id: null, data, error: { code, message } });

export async function runPatientErase(deps: EraseDeps, input: EraseInput): Promise<{ status: number; body: ActionResult }> {
  if (!input?.customerId || typeof input.requestPath !== 'string' || typeof input.typedName !== 'string' || !input.requestPath || !input.typedName) {
    return { status: 400, body: failure('INVALID_INPUT', 'customerId, requestPath and typedName are required.') };
  }

  let first = await deps.eraseRpc(input);
  if (first.error || !first.data) return { status: 500, body: failure('ACTION_FAILED', first.error?.message ?? 'The action returned nothing.') };
  let result = first.data;
  let deleted: string[] = [];

  if (!result.ok && result.error?.code === 'AUDIO_FILES_REMAIN') {
    const paths = await deps.listAudioPaths(input.customerId);
    const removed = await deps.removeAudio(paths);
    deleted = removed.removed;
    deps.log('info', 'patient-erase: recordings deleted', { customerId: input.customerId, count: deleted.length, paths: deleted });
    if (removed.error || deleted.length < paths.length) {
      const left = paths.filter((p) => !deleted.includes(p));
      deps.log('error', 'patient-erase: could not delete every recording; nothing was erased in the database', { customerId: input.customerId, deleted, left, error: removed.error });
      return { status: 502, body: failure('AUDIO_DELETE_FAILED', 'Some recordings could not be deleted. The patient has not been erased; try again.', { deleted: deleted.length, left: left.length }) };
    }
    const second = await deps.eraseRpc(input);
    if (second.error || !second.data) {
      deps.log('error', 'patient-erase: recordings are gone but the database step failed', { customerId: input.customerId, deleted, error: second.error?.message });
      return { status: 500, body: failure('ERASE_INCOMPLETE', 'The recordings were deleted but the erase did not finish. Run it again.', { deleted: deleted.length }) };
    }
    result = second.data;
    if (!result.ok) {
      deps.log('error', 'patient-erase: recordings are gone but the database refused', { customerId: input.customerId, deleted, code: result.error?.code });
      return { status: 409, body: { ...result, data: { ...(result.data ?? {}), deleted_recordings: deleted.length } } };
    }
  }

  if (!result.ok) return { status: result.error?.code === 'FORBIDDEN' ? 403 : 409, body: result };

  const authIds: string[] = Array.isArray(result.data?.auth_user_ids) ? result.data.auth_user_ids : [];
  let authDeleted = 0;
  for (const id of authIds) {
    try { if (await deps.deleteAuthUser(id)) authDeleted++; else deps.log('error', 'patient-erase: login not removed', { customerId: input.customerId, authUser: id }); }
    catch (e) { deps.log('error', 'patient-erase: login not removed', { customerId: input.customerId, authUser: id, error: String(e) }); }
  }
  const { auth_user_ids: _omit, ...rest } = result.data ?? {};
  return { status: 200, body: { ...result, data: { ...rest, deleted_recordings: deleted.length, logins_removed: authDeleted } } };
}
