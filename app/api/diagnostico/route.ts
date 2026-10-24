import {NextResponse} from 'next/server';
import {ownerSession} from '@/lib/auth';
export async function GET(){const started=performance.now();await ownerSession();return NextResponse.json({authentication_ms:Math.round(performance.now()-started),region:process.env.VERCEL_REGION||'local',at:new Date().toISOString()},{headers:{'Cache-Control':'private, no-store'}});}
