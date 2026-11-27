import React, { useState, useEffect } from 'react';
import Icon from '../../../components/AppIcon';
import Image from '../../../components/AppImage';
import { useTenant } from '../../../contexts/TenantContext';
import { fetchTreatmentsByOrgId } from '../../../services/api';
import { enrichTreatments } from '../../../services/treatmentEnrichment';

const TreatmentSelection = ({ selectedTreatment, onTreatmentSelect, selectedBranch }) => {
  const { orgId, loading: tenantLoading } = useTenant();
  const [treatments, setTreatments] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [searchQuery, setSearchQuery] = useState('');
  const [selectedCategory, setSelectedCategory] = useState('All');

  const hasUncategorized = treatments.some(s => !s.category);
  const categories = ['All', ...new Set(treatments.map(s => s.category).filter(Boolean)), ...(hasUncategorized ? ['Others'] : [])];

  const filteredTreatments = treatments.filter(treatment => {
    const matchesSearch = treatment.name.toLowerCase().includes(searchQuery.toLowerCase());
    const matchesCategory =
      selectedCategory === 'All' ||
      (selectedCategory === 'Others' ? !treatment.category : treatment.category === selectedCategory);
    return matchesSearch && matchesCategory;
  });

  useEffect(() => {
    let cancelled = false;

    async function loadTreatments() {
      if (tenantLoading) {
        return;
      }

      if (!orgId) {
        setLoading(false);
        setError('Unable to load organization data.');
        return;
      }

      setLoading(true);
      setError(null);

      try {
        const { data, error: fetchError } = await fetchTreatmentsByOrgId(orgId, selectedBranch?.id);
        if (cancelled) return;

        if (fetchError) {
          console.error('[TreatmentSelection] Fetch error:', fetchError);
          setError('Failed to load treatments. Please try again.');
          setLoading(false);
          return;
        }

        setTreatments(enrichTreatments(data || []));
        setLoading(false);
      } catch (err) {
        if (cancelled) return;
        console.error('[TreatmentSelection] Unexpected error:', err);
        setError('An unexpected error occurred.');
        setLoading(false);
      }
    }

    loadTreatments();
    return () => { cancelled = true; };
  }, [orgId, tenantLoading, selectedBranch?.id]);

  const formatPrice = (price) => {
    return new Intl.NumberFormat('en-IN', {
      style: 'currency',
      currency: 'NPR',
      minimumFractionDigits: 0
    }).format(price);
  };

  const showStickyBlock = !loading && !error && treatments.length > 0;

  return (
    <div className="space-y-4">
      {!showStickyBlock && (
        <div className="text-center mb-4">
          <div className="flex items-center justify-center space-x-2 mb-2">
            <Icon name="Sparkles" size={20} className="text-primary" />
            <h1 className="font-heading font-heading-semibold text-2xl text-text-primary">
              Choose Treatment
            </h1>
          </div>
          <p className="font-body font-body-normal text-text-secondary">
            Step 2 of 5 - Complete your spa booking journey
          </p>
        </div>
      )}

      {loading && (
        <div className="flex items-center justify-center py-12">
          <Icon name="Loader2" size={24} className="text-primary animate-spin" />
          <span className="ml-3 font-body font-body-normal text-text-secondary">Loading treatments...</span>
        </div>
      )}

      {error && (
        <div className="text-center py-12">
          <Icon name="AlertCircle" size={32} className="text-error mx-auto mb-3" />
          <p className="font-body font-body-normal text-text-secondary">{error}</p>
        </div>
      )}

      {!loading && !error && treatments.length === 0 && (
        <div className="text-center py-12">
          <Icon name="Calendar" size={32} className="text-text-secondary mx-auto mb-3" />
          <p className="font-body font-body-normal text-text-secondary">No treatments available at this time.</p>
        </div>
      )}

      {showStickyBlock && (
        <>
          <div
            className="sticky z-sticky-filter bg-background pt-7 pb-2"
            style={{ top: 'calc(var(--customer-header-h, 64px) + var(--progress-indicator-h, 67px))' }}
          >
            <div className="text-center mb-3">
              <div className="flex items-center justify-center space-x-2 mb-1">
                <Icon name="Sparkles" size={20} className="text-primary" />
                <h1 className="font-heading font-heading-semibold text-2xl text-text-primary">
                  Choose Treatment
                </h1>
              </div>
              <p className="font-body font-body-normal text-text-secondary">
                Step 2 of 5 - Complete your spa booking journey
              </p>
            </div>
            <div className="relative mb-3">
              <Icon name="Search" size={18} className="absolute left-3 top-1/2 -translate-y-1/2 text-text-secondary" />
              <input
                type="text"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search treatments..."
                className="w-full pl-10 pr-10 py-2.5 rounded-spa-lg border border-border bg-surface font-body font-body-normal text-sm text-text-primary placeholder:text-text-secondary focus:outline-hidden focus:border-primary focus:ring-1 focus:ring-primary"
              />
              {searchQuery && (
                <button
                  onClick={() => setSearchQuery('')}
                  className="absolute right-3 top-1/2 -translate-y-1/2 text-text-secondary hover:text-text-primary"
                >
                  <Icon name="X" size={16} />
                </button>
              )}
            </div>
            <div className="flex flex-wrap gap-2">
              {categories.map((category) => (
                <button
                  key={category}
                  onClick={() => setSelectedCategory(category)}
                  className={`whitespace-nowrap px-4 py-1.5 rounded-full text-sm font-body font-body-medium spa-transition-fast ${
                    selectedCategory === category
                      ? 'bg-primary text-white'
                      : 'bg-background text-text-secondary hover:bg-primary/10'
                  }`}
                >
                  {category}
                </button>
              ))}
            </div>
          </div>
        </>
      )}

      {!loading && !error && treatments.length > 0 && filteredTreatments.length === 0 && (
        <div className="text-center py-12">
          <Icon name="SearchX" size={32} className="text-text-secondary mx-auto mb-3" />
          <p className="font-body font-body-normal text-text-secondary">No treatments found matching your search.</p>
        </div>
      )}

      {!loading && !error && filteredTreatments.length > 0 && (
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {filteredTreatments.map((treatment) => (
            <div
              key={treatment.id}
              onClick={() => onTreatmentSelect(treatment)}
              className={`group bg-surface rounded-spa-lg border-2 spa-transition-fast cursor-pointer hover:spa-shadow-elevated hover:-translate-y-0.5 ${
                selectedTreatment?.id === treatment.id
                  ? 'border-primary bg-primary/5 spa-shadow-elevated -translate-y-1'
                  : 'border-border hover:border-primary/50'
              }`}
            >
              <div className="relative overflow-hidden rounded-t-spa-lg">
                <Image
                  src={treatment.image}
                  alt={treatment.name}
                  className="w-full h-48 object-cover"
                />
                <div className="absolute inset-0 flex items-center justify-center bg-black/0 opacity-0 group-hover:bg-black/30 group-hover:opacity-100 spa-transition-fast pointer-events-none">
                  <span className="px-4 py-1.5 rounded-full bg-surface text-text-primary font-body font-body-medium text-sm shadow-spa-elevated">
                    Select Treatment
                  </span>
                </div>
                <div className="absolute top-4 left-4 flex flex-col space-y-2">
                  {treatment.popularity && (
                    <span className="inline-flex items-center px-2 py-1 rounded-sm text-xs font-caption font-caption-normal bg-accent text-accent-foreground">
                      {treatment.popularity}
                    </span>
                  )}
                  {treatment.specialty && (
                    <span className="inline-flex items-center px-2 py-1 rounded-sm text-xs font-caption font-caption-normal bg-primary text-primary-foreground">
                      {treatment.specialty}
                    </span>
                  )}
                </div>
                <div className="absolute top-4 right-4 bg-surface/90 backdrop-blur-xs rounded-spa px-3 py-1">
                  <span className="font-heading font-heading-semibold text-lg text-text-primary">
                    {formatPrice(treatment.price)}
                  </span>
                </div>
              </div>

              <div className="p-4">
                <div className="flex items-start justify-between mb-2">
                  <div className="flex-1 min-w-0">
                    <h3 className="font-heading font-heading-medium text-lg text-text-primary mb-1">
                      {treatment.name}
                    </h3>
                    <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-text-secondary mb-2">
                      <div className="flex items-center space-x-1">
                        <Icon name="Clock" size={14} />
                        <span className="font-body font-body-normal text-sm">
                          {treatment.duration}
                        </span>
                      </div>
                      <span className="inline-flex items-center px-2 py-0.5 rounded-sm text-xs font-caption font-caption-normal bg-background text-text-secondary">
                        {treatment.category}
                      </span>
                    </div>
                  </div>
                  {selectedTreatment?.id === treatment.id && (
                    <div className="w-6 h-6 bg-primary rounded-full flex items-center justify-center">
                      <Icon name="Check" size={14} className="text-primary-foreground" />
                    </div>
                  )}
                </div>

                {treatment.description && (
                  <p className="font-body font-body-normal text-sm text-text-secondary mb-3 line-clamp-3">
                    {treatment.description}
                  </p>
                )}

                <div>
                  <h4 className="font-body font-body-medium text-sm text-text-primary mb-2">
                    Benefits
                  </h4>
                  <div className="flex flex-wrap gap-1">
                    {treatment.benefits.map((benefit) => (
                      <span
                        key={benefit}
                        className="inline-flex items-center px-2 py-0.5 rounded-sm text-xs font-caption font-caption-normal bg-success/10 text-success"
                      >
                        {benefit}
                      </span>
                    ))}
                  </div>
                </div>
              </div>
            </div>
        ))}
      </div>
      )}
    </div>
  );
};


export default TreatmentSelection;