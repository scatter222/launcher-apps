/**
 * Input validation utilities for network-style fields (IP addresses, CIDR
 * ranges, domain names, host:port).
 *
 * These are pure functions with no UI or framework dependencies, so they can be
 * reused anywhere — form fields, IPC handlers, config parsing, tests.
 *
 * Design goals:
 *  - Every failure returns a SPECIFIC, human-friendly message that tells the
 *    user what's wrong AND shows an example of the correct format, so the error
 *    itself nudges them toward a valid answer.
 *  - Validators are composable (host:port reuses the IP/domain validators).
 */

/** Result of validating a single value. */
export type ValidationResult =
  | { ok: true }
  | { ok: false; message: string };

const ok: ValidationResult = { ok: true };
const fail = (message: string): ValidationResult => ({ ok: false, message });

/**
 * A short, human-readable hint for each field type. Show this as helper text
 * *before* the user types (so they know the expected format up front), and keep
 * the specific error from the validators for *after* they get it wrong.
 */
export const FieldHints = {
  ipv4: 'IPv4 address, e.g. 10.0.1.11',
  ipv4Cidr: 'Network in CIDR notation, e.g. 10.0.0.0/24',
  domain: 'Domain name, e.g. api.lab.forge.local',
  hostPort: 'Host and port, e.g. api.lab.forge.local:5901',
} as const;

// ---------------------------------------------------------------------------
// IPv4
// ---------------------------------------------------------------------------

/**
 * Validates a bare IPv4 address such as `10.0.1.11`.
 * Rejects wrong part counts, non-numeric octets, out-of-range values, and
 * leading zeros (which are ambiguous — some parsers read them as octal).
 */
export function validateIpv4(raw: string): ValidationResult {
  const value = raw.trim();

  if (value.length === 0) {
    return fail('Enter an IP address, e.g. 10.0.1.11');
  }

  const parts = value.split('.');
  if (parts.length !== 4) {
    return fail(
      `An IPv4 address has 4 parts separated by dots — this has ${parts.length}. Example: 10.0.1.11`,
    );
  }

  for (const part of parts) {
    if (part.length === 0) {
      return fail('Each part must have a number, e.g. 10.0.1.11 (no empty sections)');
    }
    if (!/^\d+$/.test(part)) {
      return fail(`"${part}" isn't a number — each part must be 0–255, e.g. 10.0.1.11`);
    }
    if (part.length > 1 && part[0] === '0') {
      return fail(`Remove the leading zero from "${part}" — write 10.0.1.11, not 010.00.01.011`);
    }
    const n = Number(part);
    if (n > 255) {
      return fail(`"${part}" is too large — each part must be 0–255, e.g. 10.0.1.11`);
    }
  }

  return ok;
}

// ---------------------------------------------------------------------------
// IPv4 + CIDR (network/prefix)
// ---------------------------------------------------------------------------

/**
 * Validates an IPv4 network in CIDR notation such as `10.0.0.0/24`.
 * The address portion is validated with {@link validateIpv4} and the prefix
 * must be an integer from 0 to 32.
 */
export function validateIpv4Cidr(raw: string): ValidationResult {
  const value = raw.trim();

  if (value.length === 0) {
    return fail('Enter a network in CIDR notation, e.g. 10.0.0.0/24');
  }

  const slashCount = (value.match(/\//g) ?? []).length;
  if (slashCount === 0) {
    return fail('Add a "/" and a prefix length, e.g. 10.0.0.0/24');
  }
  if (slashCount > 1) {
    return fail('CIDR notation has exactly one "/", e.g. 10.0.0.0/24');
  }

  const [address, prefix] = value.split('/');

  const addressResult = validateIpv4(address);
  if (!addressResult.ok) {
    return addressResult;
  }

  if (!/^\d+$/.test(prefix)) {
    return fail(`The prefix after "/" must be a number 0–32, e.g. 10.0.0.0/24 (got "${prefix}")`);
  }
  if (prefix.length > 1 && prefix[0] === '0') {
    return fail(`Remove the leading zero from the prefix — write /24, not /${prefix}`);
  }
  const prefixNum = Number(prefix);
  if (prefixNum > 32) {
    return fail(`The prefix must be 0–32 (got /${prefixNum}). For a single host use /32, e.g. 10.0.1.11/32`);
  }

  return ok;
}

// ---------------------------------------------------------------------------
// Domain name
// ---------------------------------------------------------------------------

const MAX_DOMAIN_LENGTH = 253;
const MAX_LABEL_LENGTH = 63;
// A DNS label: letters/digits/hyphens, not starting or ending with a hyphen.
const LABEL_PATTERN = /^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$/;

/**
 * Validates a domain name / FQDN such as `api.lab.forge.local`.
 * Applies standard DNS rules (RFC 1035/1123): labels of 1–63 chars, made of
 * letters, digits and hyphens, not starting/ending with a hyphen, total length
 * up to 253 characters.
 */
export function validateDomain(raw: string): ValidationResult {
  const value = raw.trim();

  if (value.length === 0) {
    return fail('Enter a domain name, e.g. api.lab.forge.local');
  }
  if (value.length > MAX_DOMAIN_LENGTH) {
    return fail(`That's too long — a domain name can be at most ${MAX_DOMAIN_LENGTH} characters`);
  }
  if (value.includes(' ')) {
    return fail('Domain names can\'t contain spaces, e.g. api.lab.forge.local');
  }
  if (value.startsWith('.') || value.endsWith('.')) {
    return fail('Remove the leading/trailing dot, e.g. api.lab.forge.local');
  }
  if (value.includes('..')) {
    return fail('Domain names can\'t have empty sections ("..") — e.g. api.lab.forge.local');
  }

  const labels = value.split('.');
  for (const label of labels) {
    if (label.length > MAX_LABEL_LENGTH) {
      return fail(`The part "${label.slice(0, 12)}…" is too long — each section must be 1–63 characters`);
    }
    if (!LABEL_PATTERN.test(label)) {
      if (label.startsWith('-') || label.endsWith('-')) {
        return fail(`"${label}" can't start or end with a hyphen, e.g. api.lab.forge.local`);
      }
      return fail(`"${label}" has invalid characters — use only letters, digits and hyphens, e.g. api.lab.forge.local`);
    }
  }

  return ok;
}

// ---------------------------------------------------------------------------
// Host + port
// ---------------------------------------------------------------------------

const MAX_PORT = 65535;

/**
 * Validates a `host:port` value such as `api.lab.forge.local:5901`, where the
 * host may be either a domain name or an IPv4 address and the port is 1–65535.
 */
export function validateHostPort(raw: string): ValidationResult {
  const value = raw.trim();

  if (value.length === 0) {
    return fail('Enter a host and port, e.g. api.lab.forge.local:5901');
  }

  const lastColon = value.lastIndexOf(':');
  if (lastColon === -1) {
    return fail('Add a ":" and a port number, e.g. api.lab.forge.local:5901');
  }

  const host = value.slice(0, lastColon);
  const port = value.slice(lastColon + 1);

  if (host.length === 0) {
    return fail('Missing the host part before ":", e.g. api.lab.forge.local:5901');
  }

  // Host can be a domain OR an IPv4 address — accept whichever validates.
  const hostResult = host.includes('.') && /^[\d.]+$/.test(host)
    ? validateIpv4(host)
    : validateDomain(host);
  if (!hostResult.ok) {
    return hostResult;
  }

  if (!/^\d+$/.test(port)) {
    return fail(`The port after ":" must be a number 1–65535, e.g. :5901 (got "${port}")`);
  }
  const portNum = Number(port);
  if (portNum < 1 || portNum > MAX_PORT) {
    return fail(`The port must be between 1 and ${MAX_PORT} (got ${portNum}), e.g. api.lab.forge.local:5901`);
  }

  return ok;
}

/**
 * The validators keyed by field kind, so a form can look one up dynamically.
 */
export const Validators = {
  ipv4: validateIpv4,
  ipv4Cidr: validateIpv4Cidr,
  domain: validateDomain,
  hostPort: validateHostPort,
} as const;

export type FieldKind = keyof typeof Validators;
