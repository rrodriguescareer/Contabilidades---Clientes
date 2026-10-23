export const APP_KIND = 'gestao' as const;
export const IS_MANAGEMENT = APP_KIND === ('gestao' as string);
export const APP_TITLE = IS_MANAGEMENT ? 'Gestão de Clientes' : 'Portal IRS';
