'use client';

import { useState } from 'react';
import readXlsxFile from 'read-excel-file';
import { ErrorBox, Icon, PageTop, useAction } from '@/components/ui';
import { api } from '@/lib/api';

interface Row { name: string; phone: string; email?: string; gender?: string; joinedOn?: string }

const pick = (headers: string[], ...names: string[]) => headers.findIndex((h) => names.some((n) => h.includes(n)));

function toYmd(v: unknown): string | undefined {
  if (v instanceof Date) return v.toISOString().slice(0, 10);
  if (typeof v === 'string') {
    const m = v.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/);
    if (m) return `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
    if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return v;
  }
  return undefined;
}

export default function ImportMembers() {
  const [rows, setRows] = useState<Row[]>([]);
  const [result, setResult] = useState<{ added: number; failed: number; results: { row: number; ok: boolean; error?: string }[] } | null>(null);
  const { busy, error, setError, run } = useAction();

  const onFile = async (file: File) => {
    setResult(null);
    setError(null);
    try {
      let table: unknown[][];
      if (file.name.toLowerCase().endsWith('.csv')) {
        const text = await file.text();
        table = text.split(/\r?\n/).filter(Boolean).map((l) => l.split(',').map((c) => c.trim().replace(/^"|"$/g, '')));
      } else {
        table = (await readXlsxFile(file)) as unknown[][];
      }
      const headers = (table[0] ?? []).map((h) => String(h ?? '').toLowerCase());
      const iName = pick(headers, 'name');
      const iPhone = pick(headers, 'phone', 'mobile', 'contact');
      if (iName < 0 || iPhone < 0) throw new Error('The first row must have column names, including "Name" and "Phone" (or "Mobile").');
      const iEmail = pick(headers, 'email', 'mail');
      const iGender = pick(headers, 'gender', 'sex');
      const iJoin = pick(headers, 'join', 'date');
      const out: Row[] = table
        .slice(1)
        .filter((r) => r[iName] && r[iPhone])
        .map((r) => ({
          name: String(r[iName]).trim(),
          phone: String(r[iPhone]).trim(),
          email: iEmail >= 0 && r[iEmail] ? String(r[iEmail]).trim() : undefined,
          gender: iGender >= 0 && r[iGender] ? String(r[iGender]).trim() : undefined,
          joinedOn: iJoin >= 0 ? toYmd(r[iJoin]) : undefined,
        }));
      if (!out.length) throw new Error('No member rows found in this file.');
      setRows(out);
    } catch (e: any) {
      setRows([]);
      setError(e.message);
    }
  };

  return (
    <>
      <PageTop crumb="Members" title="Import from Excel" />
      <div className="card stack" style={{ maxWidth: 760 }}>
        <p className="mut" style={{ margin: 0 }}>
          Upload an Excel (.xlsx) or CSV file. The first row must have column names. Needed: <b>Name</b> and <b>Phone</b>. Optional: Email, Gender, Joining date. Add memberships after import.
        </p>
        <label className="btn ghost" style={{ justifySelf: 'start' }}>
          <Icon name="upload" /> Choose file
          <input type="file" accept=".xlsx,.csv" hidden onChange={(e) => e.target.files?.[0] && onFile(e.target.files[0])} />
        </label>
        <ErrorBox error={error} />
        {rows.length > 0 && !result && (
          <>
            <div className="tblwrap" style={{ maxHeight: 360, overflow: 'auto' }}>
              <table>
                <thead>
                  <tr>
                    <th>#</th>
                    <th>NAME</th>
                    <th>PHONE</th>
                    <th>EMAIL</th>
                    <th>JOINED</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.slice(0, 200).map((r, i) => (
                    <tr key={i}>
                      <td className="mut">{i + 1}</td>
                      <td>{r.name}</td>
                      <td>{r.phone}</td>
                      <td>{r.email ?? '—'}</td>
                      <td>{r.joinedOn ?? '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <button className="btn" style={{ justifySelf: 'start' }} disabled={busy} onClick={() => run(async () => setResult(await api('/members/import', { body: { rows } })))}>
              {busy ? 'Importing…' : `Import ${rows.length} members`}
            </button>
          </>
        )}
        {result && (
          <>
            <div className="alert okk">
              {result.added} added{result.failed ? `, ${result.failed} skipped` : ''}.
            </div>
            {result.results.filter((r) => !r.ok).map((r) => (
              <div key={r.row} className="small" style={{ color: 'var(--red)' }}>
                Row {r.row}: {r.error}
              </div>
            ))}
          </>
        )}
      </div>
    </>
  );
}
