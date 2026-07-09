/**
 * Example dialog demonstrating good input validation UX.
 *
 * It validates four network-style fields — an IPv4 address, an IPv4 network in
 * CIDR notation, a domain name, and a host:port — using the pure validators in
 * `../lib/validation`.
 *
 * The UX pattern shown here is the important part:
 *   1. Show a format HINT before the user types (so they aren't guessing).
 *   2. Don't nag: only show an error once the field has been "touched"
 *      (blurred or the form was submitted), not on the very first keystroke.
 *   3. When there's an error, show a SPECIFIC message that includes a correct
 *      example — the error itself teaches the right answer.
 *   4. Show a subtle "valid" affordance once the value is good.
 *   5. Keep the primary action (Save) disabled until every field is valid, and
 *      on a blocked submit, reveal all outstanding errors at once.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * NOTE ON THE INPUT COMPONENT
 * This file uses a small local `ValidatedField` built on a plain <input> so the
 * example is self-contained. Swap the marked <input> for your standard Input
 * component — the validation wiring (value/onChange/onBlur/error) is identical.
 * See the "SWAP HERE" marker below.
 * ─────────────────────────────────────────────────────────────────────────────
 */

import React, { useMemo, useState } from 'react';
import { FieldHints, Validators, type FieldKind } from '../lib/validation';

// ---------------------------------------------------------------------------
// Field definitions for this dialog
// ---------------------------------------------------------------------------

interface FieldConfig {
  key: string;
  label: string;
  kind: FieldKind;
  placeholder: string;
}

const FIELDS: FieldConfig[] = [
  { key: 'apiAddress', label: 'API server IP', kind: 'ipv4', placeholder: '10.0.1.11' },
  { key: 'subnet', label: 'Management subnet', kind: 'ipv4Cidr', placeholder: '10.0.0.0/24' },
  { key: 'apiDomain', label: 'API hostname', kind: 'domain', placeholder: 'api.lab.forge.local' },
  { key: 'console', label: 'Console endpoint', kind: 'hostPort', placeholder: 'api.lab.forge.local:5901' },
];

type FormValues = Record<string, string>;
type TouchedMap = Record<string, boolean>;

export interface NetworkSettings {
  apiAddress: string;
  subnet: string;
  apiDomain: string;
  console: string;
}

interface NetworkSettingsDialogProps {
  initialValues?: Partial<NetworkSettings>;
  onSave: (values: NetworkSettings) => void;
  onCancel: () => void;
}

// ---------------------------------------------------------------------------
// Dialog
// ---------------------------------------------------------------------------

export function NetworkSettingsDialog({
  initialValues,
  onSave,
  onCancel,
}: NetworkSettingsDialogProps): React.ReactElement {
  const [values, setValues] = useState<FormValues>(() => {
    const seed: FormValues = {};
    for (const field of FIELDS) {
      seed[field.key] = initialValues?.[field.key as keyof NetworkSettings] ?? '';
    }
    return seed;
  });
  const [touched, setTouched] = useState<TouchedMap>({});
  const [submitAttempted, setSubmitAttempted] = useState(false);

  // Validate every field on each render. Cheap (pure functions) and keeps the
  // "can we submit?" state and per-field errors perfectly in sync.
  const errors = useMemo(() => {
    const map: Record<string, string | null> = {};
    for (const field of FIELDS) {
      const result = Validators[field.kind](values[field.key]);
      map[field.key] = result.ok ? null : result.message;
    }
    return map;
  }, [values]);

  const isValid = FIELDS.every((f) => errors[f.key] === null);

  const handleChange = (key: string, next: string) => {
    setValues((prev) => ({ ...prev, [key]: next }));
  };

  const handleBlur = (key: string) => {
    setTouched((prev) => ({ ...prev, [key]: true }));
  };

  const handleSubmit = (event: React.FormEvent) => {
    event.preventDefault();
    setSubmitAttempted(true);
    if (!isValid) {
      return; // Errors for all fields become visible via `submitAttempted`.
    }
    onSave({
      apiAddress: values.apiAddress.trim(),
      subnet: values.subnet.trim(),
      apiDomain: values.apiDomain.trim(),
      console: values.console.trim(),
    });
  };

  return (
    <div style={styles.backdrop} role="dialog" aria-modal="true" aria-labelledby="netcfg-title">
      <form style={styles.dialog} onSubmit={handleSubmit} noValidate>
        <h2 id="netcfg-title" style={styles.title}>Network settings</h2>
        <p style={styles.subtitle}>Configure how the launcher reaches the API server.</p>

        {FIELDS.map((field) => {
          // An error is only *shown* once the user has left the field or tried
          // to submit — but it's always computed, so Save stays correctly gated.
          const showError = (touched[field.key] || submitAttempted) && errors[field.key] !== null;
          const showValid = values[field.key].trim().length > 0 && errors[field.key] === null;

          return (
            <ValidatedField
              key={field.key}
              id={`netcfg-${field.key}`}
              label={field.label}
              hint={FieldHints[field.kind]}
              placeholder={field.placeholder}
              value={values[field.key]}
              error={showError ? errors[field.key] : null}
              valid={showValid}
              onChange={(next) => handleChange(field.key, next)}
              onBlur={() => handleBlur(field.key)}
            />
          );
        })}

        <div style={styles.actions}>
          <button type="button" style={styles.secondaryButton} onClick={onCancel}>
            Cancel
          </button>
          <button
            type="submit"
            style={{ ...styles.primaryButton, ...(isValid ? {} : styles.primaryButtonDisabled) }}
            disabled={!isValid}
          >
            Save
          </button>
        </div>
      </form>
    </div>
  );
}

// ---------------------------------------------------------------------------
// ValidatedField — a labelled input with hint + inline error/valid state.
// ---------------------------------------------------------------------------

interface ValidatedFieldProps {
  id: string;
  label: string;
  hint: string;
  placeholder: string;
  value: string;
  /** Specific error message, or null when valid / not yet shown. */
  error: string | null;
  /** Whether to show the "looks good" affordance. */
  valid: boolean;
  onChange: (next: string) => void;
  onBlur: () => void;
}

function ValidatedField({
  id,
  label,
  hint,
  placeholder,
  value,
  error,
  valid,
  onChange,
  onBlur,
}: ValidatedFieldProps): React.ReactElement {
  const describedBy = error ? `${id}-error` : `${id}-hint`;

  return (
    <div style={styles.field}>
      <label htmlFor={id} style={styles.label}>{label}</label>

      {/* ─── SWAP HERE ──────────────────────────────────────────────────────
          Replace this <input> with your standard Input component. Keep the
          same wiring: value, onChange, onBlur, aria-invalid, aria-describedby.
          e.g.  <Input id={id} value={value} invalid={!!error}
                       onChange={onChange} onBlur={onBlur} ... />
         ──────────────────────────────────────────────────────────────────── */}
      <input
        id={id}
        type="text"
        style={{
          ...styles.input,
          ...(error ? styles.inputError : {}),
          ...(valid ? styles.inputValid : {}),
        }}
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        onBlur={onBlur}
        aria-invalid={error ? true : undefined}
        aria-describedby={describedBy}
        autoComplete="off"
        spellCheck={false}
      />

      {error ? (
        // Specific, example-bearing error. role="alert" announces it to
        // screen readers the moment it appears.
        <p id={`${id}-error`} role="alert" style={styles.errorText}>
          {error}
        </p>
      ) : (
        // Format hint shown while the field is untouched or valid.
        <p id={`${id}-hint`} style={valid ? styles.validText : styles.hintText}>
          {valid ? 'Looks good' : hint}
        </p>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Inline styles (self-contained so the example runs without external CSS).
// In the real app, prefer your standard Input/Button components and stylesheet.
// ---------------------------------------------------------------------------

const styles: Record<string, React.CSSProperties> = {
  backdrop: {
    position: 'fixed',
    inset: 0,
    background: 'rgba(0, 0, 0, 0.45)',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 16,
  },
  dialog: {
    width: '100%',
    maxWidth: 420,
    background: '#ffffff',
    color: '#1a1a1a',
    borderRadius: 10,
    padding: 24,
    boxShadow: '0 10px 40px rgba(0, 0, 0, 0.25)',
    fontFamily: 'system-ui, -apple-system, Segoe UI, Roboto, sans-serif',
  },
  title: { margin: '0 0 4px', fontSize: 18, fontWeight: 600 },
  subtitle: { margin: '0 0 20px', fontSize: 13, color: '#666' },
  field: { marginBottom: 16 },
  label: { display: 'block', fontSize: 13, fontWeight: 500, marginBottom: 6 },
  input: {
    width: '100%',
    boxSizing: 'border-box',
    padding: '8px 10px',
    fontSize: 14,
    border: '1px solid #cbd0d6',
    borderRadius: 6,
    outline: 'none',
  },
  inputError: { borderColor: '#d13438', boxShadow: '0 0 0 3px rgba(209, 52, 56, 0.12)' },
  inputValid: { borderColor: '#2f855a' },
  hintText: { margin: '6px 0 0', fontSize: 12, color: '#6b7280' },
  validText: { margin: '6px 0 0', fontSize: 12, color: '#2f855a' },
  errorText: { margin: '6px 0 0', fontSize: 12, color: '#d13438' },
  actions: { display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 8 },
  primaryButton: {
    padding: '8px 16px',
    fontSize: 14,
    fontWeight: 500,
    color: '#fff',
    background: '#2563eb',
    border: 'none',
    borderRadius: 6,
    cursor: 'pointer',
  },
  primaryButtonDisabled: { background: '#9db4e0', cursor: 'not-allowed' },
  secondaryButton: {
    padding: '8px 16px',
    fontSize: 14,
    fontWeight: 500,
    color: '#374151',
    background: '#f3f4f6',
    border: '1px solid #d1d5db',
    borderRadius: 6,
    cursor: 'pointer',
  },
};

export default NetworkSettingsDialog;
