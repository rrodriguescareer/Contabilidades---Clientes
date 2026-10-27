import { redirect } from 'next/navigation';

/* Esta página reconciliava os pagamentos da Revolut, que deixou de ser o meio
   de pagamento. Os pagamentos (Stripe) vivem agora no gabinete do IRS. */
export default function Pagamentos() {
  redirect('/irs?separador=pagamentos');
}
