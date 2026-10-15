import React, { useEffect, useRef, useState } from 'react';
import Icon from '../../../components/AppIcon';
import Button from '../../../components/ui/Button';
import { uploadConsultationFile, analyzeConsultationImages, getConsultationFileUrl } from '../../../services/api';
import { resizeImageFile } from '../../../utils/imageResize';

// X-ray / clinical-photo card: upload images to private storage, then ask the
// AI to describe them. Images stay attached even if the AI step fails.
const ImageAnalysisCard = ({ title, icon, kind, bookingId, imagePaths, analysis, onChange, onAnalysisEdit, disabled, compact = false, onBusyChange, externalBusy = null }) => {
  const inputRef = useRef(null);
  const cameraRef = useRef(null);
  const [busy, setBusy] = useState(null); // 'uploading' | 'analyzing' | null
  const [error, setError] = useState(null);
  const [retryPaths, setRetryPaths] = useState(null);
  const [previews, setPreviews] = useState({});

  useEffect(() => { onBusyChange?.(busy); }, [busy, onBusyChange]);

  // Signed URLs for thumbnails (the bucket is private).
  useEffect(() => {
    let cancelled = false;
    const missing = imagePaths.filter((p) => !previews[p]);
    if (missing.length === 0) return undefined;
    Promise.all(missing.map(async (p) => [p, (await getConsultationFileUrl('image', p)).url])).then((pairs) => {
      if (!cancelled) setPreviews((prev) => ({ ...prev, ...Object.fromEntries(pairs) }));
    });
    return () => { cancelled = true; };
  }, [imagePaths, previews]);

  const runAnalysis = async (paths, allPaths, currentAnalysis) => {
    setBusy('analyzing');
    const { analysis: text, error: aiError } = await analyzeConsultationImages(kind, paths);
    setBusy(null);
    if (aiError) {
      setError(aiError.message);
      setRetryPaths(paths);
      return;
    }
    setError(null);
    setRetryPaths(null);
    onChange({
      imagePaths: allPaths,
      analysis: currentAnalysis ? `${currentAnalysis}\n\n---\n\n${text}` : text,
    });
  };

  const handleFiles = async (e) => {
    const files = Array.from(e.target.files || []);
    e.target.value = '';
    if (files.length === 0) return;

    setError(null);
    setBusy('uploading');
    const uploaded = [];
    for (const file of files) {
      const { path, error: upError } = await uploadConsultationFile(bookingId, await resizeImageFile(file), 'image');
      if (upError) {
        setError(`${file.name}: ${upError.message}`);
        continue;
      }
      uploaded.push(path);
    }
    if (uploaded.length === 0) {
      setBusy(null);
      return;
    }
    const allPaths = [...imagePaths, ...uploaded];
    onChange({ imagePaths: allPaths, analysis });
    await runAnalysis(uploaded, allPaths, analysis);
  };

  return (
    <div className="bg-white rounded-2xl border border-gray-200/80 shadow-sm hover:shadow-md transition-shadow overflow-hidden">
      <div className="flex items-center justify-between px-5 py-3.5 border-b border-gray-100 bg-gradient-to-r from-primary/[0.05] to-transparent">
        <div className="flex items-center gap-3">
          <span className="w-9 h-9 rounded-xl bg-primary/10 text-primary flex items-center justify-center shrink-0">
            <Icon name={icon} size={18} />
          </span>
          <h2 className="font-heading font-heading-semibold text-base text-text-primary">{title}</h2>
        </div>
        <input ref={inputRef} type="file" accept="image/*" multiple hidden onChange={handleFiles} />
        {/* capture opens the phone's rear camera directly; on desktop it falls back to a file picker */}
        <input ref={cameraRef} type="file" accept="image/*" capture="environment" hidden onChange={handleFiles} />
        {!compact && (
          <div className="flex items-center gap-2">
            <Button
              variant="primary"
              size="sm"
              iconName="Camera"
              iconPosition="left"
              disabled={disabled || busy !== null}
              onClick={() => cameraRef.current?.click()}
            >
              Take photo
            </Button>
            <Button
              variant="outline"
              size="sm"
              iconName="Upload"
              iconPosition="left"
              disabled={disabled || busy !== null}
              onClick={() => inputRef.current?.click()}
            >
              Upload
            </Button>
          </div>
        )}
      </div>

      <div className="p-5">
      {compact && (
        <div className="grid grid-cols-1 gap-2 mb-4">
          <Button variant="primary" size="lg" fullWidth iconName="Camera" iconPosition="left"
                  disabled={disabled || busy !== null} onClick={() => cameraRef.current?.click()}>
            Take photo
          </Button>
          <Button variant="outline" fullWidth iconName="Image" iconPosition="left"
                  disabled={disabled || busy !== null} onClick={() => inputRef.current?.click()}>
            Choose from gallery
          </Button>
        </div>
      )}

      {imagePaths.length > 0 && (
        <div className="flex flex-wrap gap-2 mb-4">
          {imagePaths.map((p) => (
            <a key={p} href={previews[p] || undefined} target="_blank" rel="noopener noreferrer"
               className="w-20 h-20 rounded-md border border-gray-200 bg-gray-50 overflow-hidden flex items-center justify-center">
              {previews[p]
                ? <img src={previews[p]} alt={`${title} upload`} className="w-full h-full object-cover" />
                : <Icon name="Image" size={20} className="text-gray-400" />}
            </a>
          ))}
        </div>
      )}

      {(busy || externalBusy) && (
        <div className="flex items-center gap-2 text-sm text-text-secondary mb-3">
          <div className="animate-spin w-4 h-4 border-2 border-primary border-t-transparent rounded-full" />
          {busy
            ? (busy === 'uploading' ? 'Uploading images…' : 'Analysing images…')
            : (externalBusy === 'uploading' ? 'Receiving images from the phone…' : 'Phone image is being analysed…')}
        </div>
      )}

      {error && (
        <div className="mb-3 p-3 bg-error/5 border border-error/20 rounded-md flex items-start gap-2">
          <Icon name="AlertCircle" size={16} className="text-error mt-0.5 shrink-0" />
          <div className="flex-1 text-sm text-text-secondary">
            {error}
            {retryPaths && (
              <button
                type="button"
                className="ml-2 text-primary font-medium hover:underline"
                onClick={() => runAnalysis(retryPaths, imagePaths, analysis)}
                disabled={busy !== null}
              >
                Retry analysis
              </button>
            )}
          </div>
        </div>
      )}

      {compact ? (
        imagePaths.length > 0 && (
          <p className="text-xs text-text-tertiary flex items-center gap-1">
            <Icon name="Check" size={12} /> {imagePaths.length} sent to the computer{analysis ? ' · analysis added' : ''}
          </p>
        )
      ) : (
        <textarea
          value={analysis}
          onChange={(e) => onAnalysisEdit(e.target.value)}
          disabled={disabled}
          rows={analysis ? 8 : 3}
          placeholder={`${title} will appear here after you upload images. You can also type or edit findings yourself.`}
          className="w-full text-sm leading-relaxed rounded-xl border-gray-200 bg-gray-50/50 px-4 py-3 placeholder:text-gray-400 focus:bg-white focus:border-primary focus:ring-2 focus:ring-primary/20 transition"
        />
      )}
      </div>
    </div>
  );
};

export default ImageAnalysisCard;
