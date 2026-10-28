export const LEGAL_VERSION='2026-10-28.1';
export const LEGAL_ACCEPTED_VALUE='accepted';
export function acceptedLegal(form:FormData){return form.get('consent')===LEGAL_ACCEPTED_VALUE;}
