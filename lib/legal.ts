export const LEGAL_VERSION='2026-10-23.3';
export const LEGAL_ACCEPTED_VALUE='accepted';
export function acceptedLegal(form:FormData){return form.get('consent')===LEGAL_ACCEPTED_VALUE;}
