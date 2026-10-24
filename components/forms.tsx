'use client';
import { useFormStatus } from 'react-dom';

/** Botão de submissão que se desativa sozinho enquanto a ação corre. */
export function Submeter({
  children,
  aDecorrer = 'A guardar…',
  className = 'btn btn-bloco',
}: {
  children: React.ReactNode;
  aDecorrer?: string;
  className?: string;
}) {
  const { pending } = useFormStatus();
  return (
    <button className={className} type="submit" disabled={pending}>
      {pending ? aDecorrer : children}
    </button>
  );
}
