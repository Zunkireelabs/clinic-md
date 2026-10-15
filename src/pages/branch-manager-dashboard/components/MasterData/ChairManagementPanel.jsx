import React, { useState, useEffect, useCallback, useMemo } from 'react';
import Icon from '../../../../components/AppIcon';
import Button from '../../../../components/ui/Button';
import Input from '../../../../components/ui/Input';
import { useIndustry } from '../../../../hooks/useIndustry';
import {
  fetchChairsForManagement,
  createChair,
  updateChair,
  toggleChairActive,
  deleteChair,
} from '../../../../services/api';

const ChairManagementPanel = ({ branchId }) => {
  const { enableChairs, locationLabel, locationLabelPlural } = useIndustry();
  const [chairs, setChairs] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [searchQuery, setSearchQuery] = useState('');
  const [selectedAmenity, setSelectedAmenity] = useState('All');
  const [showModal, setShowModal] = useState(false);
  const [editingChair, setEditingChair] = useState(null);
  const [formName, setFormName] = useState('');
  const [formAmenities, setFormAmenities] = useState('');
  const [formFloor, setFormFloor] = useState('');
  const [formCapacity, setFormCapacity] = useState('1');
  const [formError, setFormError] = useState(null);
  const [saving, setSaving] = useState(false);
  const [confirmToggle, setConfirmToggle] = useState(null);
  const [confirmDelete, setConfirmDelete] = useState(null);
  const [deleting, setDeleting] = useState(false);

  const allUniqueAmenities = useMemo(() => {
    const amenities = new Set();
    chairs.forEach(r => {
      if (r.amenities) {
        r.amenities.forEach(a => amenities.add(a));
      }
    });
    return ['All', ...Array.from(amenities).sort()];
  }, [chairs]);

  const filteredChairs = useMemo(() => {
    const filtered = chairs.filter(chair => {
      const matchesSearch = chair.name.toLowerCase().includes(searchQuery.toLowerCase());
      const matchesAmenity = selectedAmenity === 'All' || (chair.amenities && chair.amenities.includes(selectedAmenity));
      return matchesSearch && matchesAmenity;
    });
    return filtered;
  }, [chairs, searchQuery, selectedAmenity]);

  const loadChairs = useCallback(async () => {
    if (!branchId) return;
    setLoading(true);
    setError(null);
    const result = await fetchChairsForManagement(branchId);
    
    if (result.error) {
      setError(result.error.message || 'Failed to load chairs.');
    } else {
      setChairs(result.data || []);
    }
    setLoading(false);
  }, [branchId]);

  useEffect(() => { loadChairs(); }, [loadChairs, branchId]);

  const handleOpenCreate = () => {
    setEditingChair(null);
    setFormName('');
    setFormAmenities('');
    setFormFloor('');
    setFormCapacity('1');
    setFormError(null);
    setShowModal(true);
  };

  const handleOpenEdit = (chair) => {
    setEditingChair(chair);
    setFormName(chair.name);
    setFormAmenities(chair.amenities ? chair.amenities.join(', ') : '');
    setFormFloor(chair.floor || '');
    setFormCapacity(String(chair.capacity ?? 1));
    setFormError(null);
    setShowModal(true);
  };

  const handleSave = async () => {
    if (!formName.trim()) {
      setFormError('Chair name is required.');
      return;
    }
    const capacityValue = parseInt(formCapacity, 10);
    if (!capacityValue || capacityValue < 1) {
      setFormError('Capacity must be at least 1.');
      return;
    }
    setSaving(true);
    setFormError(null);
    const amenitiesArray = formAmenities.split(',').map(s => s.trim()).filter(Boolean);
    const floorValue = formFloor.trim() || null;
    let result;
    if (editingChair) {
      result = await updateChair({ chairId: editingChair.id, name: formName.trim(), amenities: amenitiesArray, floor: floorValue, capacity: capacityValue });
    } else {
      result = await createChair({ name: formName.trim(), branchId, amenities: amenitiesArray, floor: floorValue, capacity: capacityValue });
    }
    if (result.error) {
      setFormError(result.error.message || 'Operation failed.');
    } else {
      setShowModal(false);
      await loadChairs();
    }
    setSaving(false);
  };

  const handleDelete = async () => {
    if (!confirmDelete) return;
    setDeleting(true);
    setError(null);
    const result = await deleteChair({ chairId: confirmDelete.id });
    if (result.error) {
      setError(result.error.code === 'HAS_BOOKINGS' ? 'Cannot delete chair with history.' : result.error.message);
    } else {
      await loadChairs();
    }
    setConfirmDelete(null);
    setDeleting(false);
  };

  if (!enableChairs) return null;

  if (loading) {
    return (
      <div className="text-center py-12">
        <div className="animate-spin w-8 h-8 border-2 border-primary border-t-transparent rounded-full mx-auto mb-3" />
        <p className="text-sm text-text-secondary">Loading {locationLabelPlural}...</p>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <p className="font-body text-sm text-text-secondary">{chairs.length} {locationLabelPlural} configured</p>
        </div>
        <Button variant="primary" size="sm" iconName="Plus" onClick={handleOpenCreate}>
          Add {locationLabel}
        </Button>
      </div>

      <div className="bg-surface border border-border rounded-spa p-3 space-y-3">
        <div className="relative">
          <Icon name="Search" size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-text-secondary" />
          <input
            type="text"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            placeholder={"Search " + locationLabelPlural + "..."}
            className="w-full pl-9 pr-4 py-2 bg-background border border-border rounded-spa font-body text-sm focus:outline-none focus:ring-1 focus:ring-primary focus:border-primary"
          />
        </div>
        {allUniqueAmenities.length > 1 && (
          <div className="flex flex-wrap gap-2 items-center">
            <span className="text-[10px] text-text-secondary uppercase font-bold mr-1">Filter by Feature:</span>
            {allUniqueAmenities.map(amenity => (
              <button
                key={amenity}
                onClick={() => setSelectedAmenity(amenity)}
                className={"px-3 py-1 rounded-full text-xs transition-colors " + (selectedAmenity === amenity ? 'bg-primary text-white' : 'bg-background text-text-secondary hover:bg-primary/10')}
              >
                {amenity}
              </button>
            ))}
          </div>
        )}
      </div>

      {error && (
        <div className="p-3 bg-error/10 border border-error/20 rounded-spa text-error text-sm flex items-center gap-2">
          <Icon name="AlertCircle" size={16} />
          <span>{error}</span>
          <button onClick={() => setError(null)} className="ml-auto"><Icon name="X" size={14} /></button>
        </div>
      )}

      <div className="bg-surface border border-border rounded-spa overflow-hidden">
        <table className="w-full">
          <thead>
            <tr className="bg-background border-b border-border">
              <th className="text-left px-4 py-3 text-sm text-text-secondary">{locationLabel} Name</th>
              <th className="text-left px-4 py-3 text-sm text-text-secondary">Floor</th>
              <th className="text-left px-4 py-3 text-sm text-text-secondary">Amenities</th>
              <th className="text-left px-4 py-3 text-sm text-text-secondary">Capacity</th>
              <th className="text-left px-4 py-3 text-sm text-text-secondary">Status</th>
              <th className="text-right px-4 py-3 text-sm text-text-secondary">Actions</th>
            </tr>
          </thead>
          <tbody>
            {filteredChairs.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-text-secondary text-sm">
                  No {locationLabelPlural} found.
                </td>
              </tr>
            ) : (
              filteredChairs.map((chair) => (
                <tr key={chair.id} className="border-b border-border last:border-b-0 hover:bg-background/50">
                  <td className="px-4 py-3 font-medium text-sm">{chair.name}</td>
                  <td className="px-4 py-3 text-sm text-text-secondary">{chair.floor || '—'}</td>
                  <td className="px-4 py-3">
                    <div className="flex flex-wrap gap-1">
                      {chair.amenities?.map((a, i) => (
                        <span key={i} className="px-2 py-0.5 rounded bg-primary/5 text-primary text-[10px] uppercase font-bold">{a}</span>
                      )) || <span className="text-text-tertiary italic text-[10px]">No features added</span>}
                    </div>
                  </td>
                  <td className="px-4 py-3 text-sm text-text-secondary">{chair.capacity ?? 1}</td>
                  <td className="px-4 py-3">
                    <span className={"px-2 py-0.5 rounded text-xs " + (chair.is_active ? 'bg-success/10 text-success' : 'bg-gray-100 text-gray-500')}>
                      {chair.is_active ? 'Active' : 'Inactive'}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <div className="flex justify-end gap-2">
                      <button onClick={() => handleOpenEdit(chair)} className="p-1 hover:text-primary"><Icon name="Pencil" size={16} /></button>
                      <button onClick={() => setConfirmDelete(chair)} className="p-1 hover:text-error"><Icon name="Trash2" size={16} /></button>
                    </div>
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {showModal && (
        <div className="fixed inset-0 z-modal-overlay bg-black/50 flex items-center justify-center p-4" onClick={() => setShowModal(false)}>
          <div className="bg-surface rounded-spa-lg w-full max-w-md p-6" onClick={e => e.stopPropagation()}>
            <h3 className="text-lg font-bold mb-4">{editingChair ? 'Edit' : 'Add'} {locationLabel}</h3>
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium mb-1">{locationLabel} Name</label>
                <Input value={formName} onChange={e => setFormName(e.target.value)} autoFocus />
              </div>
              <div>
                <label className="block text-sm font-medium mb-1">Floor</label>
                <Input value={formFloor} onChange={e => setFormFloor(e.target.value)} placeholder="e.g., Ground Floor, VIP Floor" />
              </div>
              <div>
                <label className="block text-sm font-medium mb-1">Amenities (comma separated)</label>
                <Input value={formAmenities} onChange={e => setFormAmenities(e.target.value)} />
              </div>
              <div>
                <label className="block text-sm font-medium mb-1">Capacity (concurrent bookings)</label>
                <Input type="number" min="1" value={formCapacity} onChange={e => setFormCapacity(e.target.value)} />
              </div>
              <div className="flex justify-end gap-2 pt-4">
                <Button variant="ghost" onClick={() => setShowModal(false)}>Cancel</Button>
                <Button variant="primary" onClick={handleSave} loading={saving}>Save</Button>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default ChairManagementPanel;