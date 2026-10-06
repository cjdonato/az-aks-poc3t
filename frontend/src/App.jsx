import { useEffect, useState } from 'react';

async function api(path, options = {}) {
  const res = await fetch(`/api${path}`, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.error ?? `${res.status} ${res.statusText}`);
  }
  return res.status === 204 ? null : res.json();
}

export default function App() {
  const [items, setItems] = useState([]);
  const [info, setInfo] = useState(null);
  const [name, setName] = useState('');
  const [error, setError] = useState(null);

  async function refresh() {
    try {
      const [list, meta] = await Promise.all([api('/items'), api('/info')]);
      setItems(list);
      setInfo(meta);
      setError(null);
    } catch (err) {
      setError(err.message);
    }
  }

  useEffect(() => {
    refresh();
  }, []);

  async function addItem(e) {
    e.preventDefault();
    if (!name.trim()) return;
    try {
      await api('/items', { method: 'POST', body: JSON.stringify({ name }) });
      setName('');
      await refresh();
    } catch (err) {
      setError(err.message);
    }
  }

  async function deleteItem(id) {
    try {
      await api(`/items/${id}`, { method: 'DELETE' });
      await refresh();
    } catch (err) {
      setError(err.message);
    }
  }

  return (
    <main>
      <h1>Three-Tier PoC</h1>
      <p className="tiers">React → Express API → PostgreSQL</p>

      <form onSubmit={addItem}>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="New item"
          maxLength={200}
          aria-label="New item name"
        />
        <button type="submit">Add</button>
      </form>

      {error && <p className="error">Error: {error}</p>}

      <ul>
        {items.map((item) => (
          <li key={item.id}>
            <span>{item.name}</span>
            <button onClick={() => deleteItem(item.id)} aria-label={`Delete ${item.name}`}>
              ✕
            </button>
          </li>
        ))}
        {items.length === 0 && !error && <li className="empty">No items yet</li>}
      </ul>

      {info && (
        <footer>
          Served by API pod <code>{info.hostname}</code> · version <code>{info.version}</code>{' '}
          <button className="link" onClick={refresh}>
            refresh
          </button>
        </footer>
      )}
    </main>
  );
}
