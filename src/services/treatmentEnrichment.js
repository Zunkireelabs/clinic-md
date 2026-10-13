const TREATMENT_UI_DATA = {
  'Dental Cleaning': {
    image: 'https://images.unsplash.com/photo-1598256989800-fe5f95da9787?w=400&h=300&fit=crop',
    benefits: ['Removes plaque & tartar', 'Freshens breath', 'Prevents gum disease'],
    dentistPreference: ['male', 'female'],
    category: 'Preventive',
    popularity: 'Most Popular',
    specialty: null,
  },
  'Cavity Filling': {
    image: 'https://images.unsplash.com/photo-1588776814546-daab30f310ce?w=400&h=300&fit=crop',
    benefits: ['Stops tooth decay', 'Restores tooth strength', 'Pain relief'],
    dentistPreference: ['male', 'female'],
    category: 'Restorative',
    popularity: null,
    specialty: null,
  },
  'Root Canal Treatment': {
    image: 'https://images.unsplash.com/photo-1588776814546-1ffcf47267a5?w=400&h=300&fit=crop',
    benefits: ['Saves the natural tooth', 'Eliminates infection', 'Relieves pain'],
    dentistPreference: ['male', 'female'],
    category: 'Restorative',
    popularity: null,
    specialty: 'Signature Treatment',
  },
  'Teeth Whitening': {
    image: 'https://images.unsplash.com/photo-1594824476967-48c8b964273f?w=400&h=300&fit=crop',
    benefits: ['Brighter smile', 'Removes stains', 'Boosts confidence'],
    dentistPreference: ['male', 'female'],
    category: 'Cosmetic',
    popularity: null,
    specialty: null,
  },
  'Braces Consultation': {
    image: 'https://images.unsplash.com/photo-1606811841689-23dfddce3e95?w=400&h=300&fit=crop',
    benefits: ['Personalized treatment plan', 'Improves bite alignment', 'Expert assessment'],
    dentistPreference: ['male', 'female'],
    category: 'Orthodontic',
    popularity: null,
    specialty: null,
  },
  'Pediatric Checkup': {
    image: 'https://images.unsplash.com/photo-1609207825181-52d3214556dd?w=400&h=300&fit=crop',
    benefits: ['Early cavity detection', 'Gentle child-friendly care', 'Healthy habit building'],
    dentistPreference: ['male', 'female'],
    category: 'Pediatric',
    popularity: null,
    specialty: null,
  },
};

const DEFAULT_UI_DATA = {
  image: 'https://images.unsplash.com/photo-1629909613654-28e377c37b09?w=400&h=300&fit=crop',
  benefits: ['Expert dental care', 'Modern equipment'],
  dentistPreference: ['male', 'female'],
  category: 'General',
  popularity: null,
  specialty: null,
};

export function enrichTreatment(dbTreatment) {
  const uiData = TREATMENT_UI_DATA[dbTreatment.name] || DEFAULT_UI_DATA;

  return {
    id: dbTreatment.id,
    name: dbTreatment.name,
    description: dbTreatment.description,
    duration: `${dbTreatment.duration_minutes} minutes`,
    durationMinutes: dbTreatment.duration_minutes,
    price: Number(dbTreatment.price_npr),
    // Prefer database image_url over hardcoded fallback
    image: dbTreatment.image_url || uiData.image,
    benefits: uiData.benefits,
    dentistPreference: uiData.dentistPreference,
    // Prefer database category over hardcoded fallback
    category: dbTreatment.category || uiData.category,
    popularity: uiData.popularity,
    specialty: uiData.specialty,
  };
}

export function enrichTreatments(dbTreatments) {
  return dbTreatments.map(enrichTreatment);
}
