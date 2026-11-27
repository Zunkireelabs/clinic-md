import type { EraseDeps } from './patient-erase.ts';

// Builds the real dependencies for runPatientErase from two supabase-js clients: `user` acts as the caller (their JWT) and `service` is the
// service-role client. No imports of supabase-js here, so the edge function (Deno, esm.sh) and the local integration script (Node) share it.
export const AUDIO_BUCKET = 'consultation-audio';

export function buildEraseDeps(user: any, service: any, orgId: string, log: EraseDeps['log']): EraseDeps {
  return {
    eraseRpc: (i) => user.rpc('act_patient_erase', { p_customer: i.customerId, p_request_path: i.requestPath, p_typed_name: i.typedName }),
    listAudioPaths: async (customerId) => {
      const paths = new Set<string>();
      const { data: cons } = await service.from('consultations').select('audio_paths').eq('customer_id', customerId);
      for (const c of cons ?? []) for (const p of (c.audio_paths ?? []) as string[]) if (p.startsWith(`${orgId}/`)) paths.add(p);
      const { data: bks } = await service.from('bookings').select('id').eq('customer_id', customerId);
      for (const b of bks ?? []) {
        const { data: objs } = await service.storage.from(AUDIO_BUCKET).list(`${orgId}/${b.id}`, { limit: 1000 });
        for (const o of objs ?? []) if (o.name) paths.add(`${orgId}/${b.id}/${o.name}`);
      }
      return [...paths];
    },
    removeAudio: async (paths) => {
      const removed: string[] = [];
      for (let i = 0; i < paths.length; i += 100) {
        const { data, error } = await service.storage.from(AUDIO_BUCKET).remove(paths.slice(i, i + 100));
        if (error) return { removed, error: error.message };
        for (const o of data ?? []) removed.push(o.name);
      }
      return { removed, error: null };
    },
    deleteAuthUser: async (id) => !(await service.auth.admin.deleteUser(id)).error,
    log,
  };
}
