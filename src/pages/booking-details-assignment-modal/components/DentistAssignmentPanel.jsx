import React, { useState } from 'react';
import Icon from '../../../components/AppIcon';
import Image from '../../../components/AppImage';
import Button from '../../../components/ui/Button';
import { to12h } from '../../../services/bookingTransformers';

const DentistAssignmentPanel = ({ 
  booking, 
  availableDentists, 
  onAssignDentist, 
  isLoading,
  currentAssignment 
}) => {
  const [selectedDentist, setSelectedDentist] = useState(currentAssignment?.dentistId || '');
  const [assignmentNotes, setAssignmentNotes] = useState(currentAssignment?.notes || '');
  const [showAvailabilityMatrix, setShowAvailabilityMatrix] = useState(false);

  const handleAssignment = () => {
    if (selectedDentist) {
      onAssignDentist(selectedDentist, assignmentNotes);
    }
  };

  const getDentistAvailability = (dentist) => {
    const conflicts = dentist.schedule.filter(slot => 
      slot.date === booking.date && 
      slot.time === booking.time
    );
    return conflicts.length === 0;
  };

  const getMatchScore = (dentist) => {
    let score = 0;
    
    // Gender preference match
    if (booking.dentistGenderPreference === 'any' || 
        dentist.gender === booking.dentistGenderPreference) {
      score += 30;
    }
    
    // Treatment specialty match
    if (dentist.specialties.includes(booking.treatment)) {
      score += 40;
    }
    
    // Experience level
    score += Math.min(dentist.experienceYears * 2, 20);
    
    // Customer rating
    score += Math.min(dentist.rating * 2, 10);
    
    return Math.min(score, 100);
  };

  const sortedDentists = [...availableDentists].sort((a, b) => {
    const aAvailable = getDentistAvailability(a);
    const bAvailable = getDentistAvailability(b);
    
    if (aAvailable && !bAvailable) return -1;
    if (!aAvailable && bAvailable) return 1;
    
    return getMatchScore(b) - getMatchScore(a);
  });

  return (
    <div className="space-y-6">
      {/* Assignment Header */}
      <div className="flex items-center justify-between">
        <div>
          <h3 className="font-heading font-heading-semibold text-lg text-text-primary">
            Dentist Assignment
          </h3>
          <p className="font-caption font-caption-normal text-sm text-text-secondary">
            {booking.date} • {to12h(booking.time)} • {booking.duration}
          </p>
        </div>
        <Button
          variant="outline"
          size="sm"
          onClick={() => setShowAvailabilityMatrix(!showAvailabilityMatrix)}
          iconName={showAvailabilityMatrix ? "EyeOff" : "Eye"}
          iconPosition="left"
        >
          {showAvailabilityMatrix ? 'Hide' : 'Show'} Matrix
        </Button>
      </div>

      {/* Current Assignment */}
      {currentAssignment && (
        <div className="bg-success/5 border border-success/20 rounded-spa p-4">
          <div className="flex items-center space-x-3">
            <Icon name="UserCheck" size={20} className="text-success" />
            <div>
              <p className="font-body font-body-medium text-sm text-text-primary">
                Currently assigned to {currentAssignment.dentistName}
              </p>
              <p className="font-caption font-caption-normal text-xs text-text-secondary">
                Assigned {currentAssignment.assignedAt}
              </p>
            </div>
          </div>
        </div>
      )}

      {/* Availability Matrix */}
      {showAvailabilityMatrix && (
        <div className="bg-background rounded-spa p-4 space-y-3">
          <h4 className="font-heading font-heading-medium text-base text-text-primary">
            Availability Matrix
          </h4>
          <div className="grid grid-cols-1 gap-2">
            {sortedDentists.map((dentist) => {
              const isAvailable = getDentistAvailability(dentist);
              const matchScore = getMatchScore(dentist);
              
              return (
                <div 
                  key={dentist.id}
                  className={`flex items-center space-x-3 p-2 rounded border ${
                    isAvailable ? 'border-success/20 bg-success/5' : 'border-error/20 bg-error/5'
                  }`}
                >
                  <div className={`w-3 h-3 rounded-full ${
                    isAvailable ? 'bg-success' : 'bg-error'
                  }`}></div>
                  <span className="font-body font-body-medium text-sm text-text-primary flex-1">
                    {dentist.name}
                  </span>
                  <span className="font-caption font-caption-normal text-xs text-text-secondary">
                    {matchScore}% match
                  </span>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Dentist Selection */}
      <div className="space-y-4">
        <h4 className="font-heading font-heading-medium text-base text-text-primary">
          Available Dentists
        </h4>
        
        <div className="space-y-3 max-h-96 overflow-y-auto">
          {sortedDentists.map((dentist) => {
            const isAvailable = getDentistAvailability(dentist);
            const matchScore = getMatchScore(dentist);
            const isSelected = selectedDentist === dentist.id;
            
            return (
              <label
                key={dentist.id}
                className={`flex items-start space-x-4 p-4 rounded-spa border-2 cursor-pointer spa-transition-fast ${
                  !isAvailable 
                    ? 'opacity-50 cursor-not-allowed border-border bg-background/50'
                    : isSelected
                      ? 'border-primary bg-primary/5' :'border-border hover:border-primary/50'
                }`}
              >
                <input
                  type="radio"
                  name="dentist"
                  value={dentist.id}
                  checked={isSelected}
                  onChange={(e) => setSelectedDentist(e.target.value)}
                  disabled={!isAvailable}
                  className="mt-1 text-primary focus:ring-primary"
                />
                
                <Image 
                  src={dentist.avatar}
                  alt={dentist.name}
                  className="w-12 h-12 rounded-full object-cover"
                />
                
                <div className="flex-1 space-y-2">
                  <div className="flex items-center justify-between">
                    <div>
                      <h5 className="font-body font-body-semibold text-base text-text-primary">
                        {dentist.name}
                      </h5>
                      <p className="font-caption font-caption-normal text-sm text-text-secondary">
                        {dentist.experienceYears} years experience • {dentist.gender}
                      </p>
                    </div>
                    <div className="text-right">
                      <div className="flex items-center space-x-1">
                        <Icon name="Star" size={14} className="text-accent fill-current" />
                        <span className="font-caption font-caption-normal text-sm text-text-primary">
                          {dentist.rating}
                        </span>
                      </div>
                      <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-caption font-caption-normal ${
                        matchScore >= 80 ? 'bg-success/10 text-success' :
                        matchScore >= 60 ? 'bg-warning/10 text-warning': 'bg-text-secondary/10 text-text-secondary'
                      }`}>
                        {matchScore}% match
                      </span>
                    </div>
                  </div>
                  
                  <div className="flex flex-wrap gap-1">
                    {dentist.specialties.map((specialty) => (
                      <span 
                        key={specialty}
                        className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-caption font-caption-normal ${
                          specialty === booking.treatment 
                            ? 'bg-primary/10 text-primary' :'bg-accent/10 text-accent'
                        }`}
                      >
                        {specialty}
                      </span>
                    ))}
                  </div>
                  
                  <div className="flex items-center space-x-4 text-xs text-text-secondary">
                    <span className="flex items-center space-x-1">
                      <Icon name="Calendar" size={12} />
                      <span className="font-caption font-caption-normal">
                        {dentist.todayBookings} bookings today
                      </span>
                    </span>
                    <span className="flex items-center space-x-1">
                      <Icon name="Clock" size={12} />
                      <span className="font-caption font-caption-normal">
                        Next available: {dentist.nextAvailable}
                      </span>
                    </span>
                  </div>
                  
                  {!isAvailable && (
                    <div className="flex items-center space-x-2 text-error">
                      <Icon name="AlertCircle" size={14} />
                      <span className="font-caption font-caption-normal text-xs">
                        Conflict: {dentist.conflictReason}
                      </span>
                    </div>
                  )}
                </div>
              </label>
            );
          })}
        </div>
      </div>

      {/* Treatment Notes — saved to the customer's treatment history on assignment */}
      <div className="space-y-2">
        <label className="inline-block font-body font-body-medium text-sm text-text-primary">
          Treatment Notes
        </label>
        <textarea
          value={assignmentNotes}
          onChange={(e) => setAssignmentNotes(e.target.value)}
          placeholder="Add treatment notes — saved to the patient's history..."
          rows={3}
          className="w-full px-3 py-2 border border-border rounded-spa bg-surface text-text-primary focus:ring-2 focus:ring-primary focus:border-primary spa-transition-fast resize-none"
        />
      </div>

      {/* Assignment Actions */}
      <div className="flex items-center justify-between pt-4 border-t border-border">
        <div className="flex items-center space-x-2 text-text-secondary">
          <Icon name="Info" size={16} />
          <span className="font-caption font-caption-normal text-xs">
            Customer will be notified automatically
          </span>
        </div>
        
        <div className="flex items-center space-x-3">
          {currentAssignment && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => onAssignDentist(null, '')}
              loading={isLoading}
              iconName="UserX"
              iconPosition="left"
            >
              Unassign
            </Button>
          )}
          
          <Button
            variant="primary"
            onClick={handleAssignment}
            loading={isLoading}
            disabled={!selectedDentist}
            iconName="UserCheck"
            iconPosition="left"
          >
            {currentAssignment ? 'Reassign' : 'Assign'} Dentist
          </Button>
        </div>
      </div>
    </div>
  );
};

export default DentistAssignmentPanel;