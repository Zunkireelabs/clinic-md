import React, { createContext, useContext, useState, useCallback } from 'react';

const AIAssistantContext = createContext(null);

export const AIAssistantProvider = ({ children }) => {
  const [isOpen, setIsOpen] = useState(false);

  // A prompt handed over by the command palette ("Ask Assistant: …"); the panel consumes it once and clears it.
  const [pendingPrompt, setPendingPrompt] = useState(null);

  // openAssistant() opens the panel; openAssistant({ prompt }) also queues a first message. (Called directly or as an event
  // handler, so anything that isn't a `{ prompt }` option object is ignored.)
  const openAssistant = useCallback((opts) => {
    if (opts && typeof opts === 'object' && typeof opts.prompt === 'string' && opts.prompt.trim()) {
      setPendingPrompt(opts.prompt.trim());
    }
    setIsOpen(true);
  }, []);
  const consumePrompt = useCallback(() => setPendingPrompt(null), []);
  const closeAssistant = useCallback(() => setIsOpen(false), []);
  const toggleAssistant = useCallback(() => setIsOpen(prev => !prev), []);

  return (
    <AIAssistantContext.Provider
      value={{
        isOpen,
        pendingPrompt,
        consumePrompt,
        openAssistant,
        closeAssistant,
        toggleAssistant,
      }}
    >
      {children}
    </AIAssistantContext.Provider>
  );
};

export const useAIAssistant = () => {
  const context = useContext(AIAssistantContext);
  if (!context) {
    throw new Error('useAIAssistant must be used within an AIAssistantProvider');
  }
  return context;
};

export default AIAssistantContext;
