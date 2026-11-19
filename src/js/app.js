// app.js
// Application initialization, main logic, data sync

import { $, auth, db } from './db.js';
import { onAuthStateChanged, signOut } from 'https://www.gstatic.com/firebasejs/10.8.0/firebase-auth.js';
import { collection, doc, onSnapshot, query, orderBy, limit, where } from 'https://www.gstatic.com/firebasejs/10.8.0/firebase-firestore.js';
import { initUI, setupModals, showToast } from './ui.js';
import { initChart } from './charts.js';
import './auth.js';

let currentUser = null;
let accountsUnsubscribe = null;
let tradesUnsubscribe = null;
let snapshotsUnsubscribe = null;
let authUnsubscribe = null;

// Format numbers for display
function fmt(num) { return num ? num.toLocaleString('fr-FR', {minimumFractionDigits: 2}) : '0'; }
function sg(num) { return (num < 0 ? '' : '+') + fmt(num); }
function cl(num) { return num > 0 ? 'g' : num < 0 ? 'r' : ''; }

// Initialize main application
export function initApp() {
  // Load saved theme
  const theme = localStorage.getItem('dasexpertpro-theme') || 'dark';
  document.documentElement.dataset.theme = theme;

  // Setup auth state listener
  authUnsubscribe = onAuthStateChanged(auth, (user) => {
    if (user) {
      currentUser = user;
      showToast('Connexion réussie', 'success');
      // Load user data
      loadAccounts();
      loadTrades();
      loadSnapshots();
    } else {
      currentUser = null;
      // Clear data
      accountsUnsubscribe && accountsUnsubscribe();
      tradesUnsubscribe && tradesUnsubscribe();
      snapshotsUnsubscribe && snapshotsUnsubscribe();
    }
  });

  // Setup logout button
  $('#bOut').onclick = () => {
    signOut(auth).then(() => {
      showToast('Déconnexion réussie', 'info');
    });
  };

  // Initialize UI
  initUI();
  setupModals();
  setupVisibilityHandler();

  // Initialize dashboard chart
  initDashboardChart();
}

// Load accounts for current user
function loadAccounts() {
  const accountsRef = collection(db, 'accounts');
  const q = query(accountsRef, where('ownerId', '==', currentUser.uid));
  
  accountsUnsubscribe = onSnapshot(q, (snapshot) => {
    const accounts = [];
    snapshot.forEach(doc => {
      accounts.push({ id: doc.id, data: doc.data() });
    });
    updateAccountsUI(accounts);
  }, (error) => {
    showToast('Erreur de chargement des comptes: ' + error.message, 'error');
  });
}

// Update accounts UI
function updateAccountsUI(accounts) {
  const hmSum = $('#hmSum');
  hmSum.innerHTML = '';
  
  accounts.forEach(account => {
    const balance = account.data.balance || 0;
    const equity = account.data.equity || 0;
    const pnl = account.data.pnl || 0;
    
    const card = document.createElement('div');
    card.className = 'card';
    card.innerHTML = `
      <div class="l">Compte ${account.id}</div>
      <div class="v ${cl(pnl)}">${sg(pnl)}</div>
      <div class="d">Solde: ${fmt(balance)}</div>
    `;
    hmSum.appendChild(card);
  });
}

// Load trades for current user
function loadTrades() {
  const tradesRef = collection(db, 'trades');
  const q = query(tradesRef, where('accountId', '==', currentUser.uid));
  
  tradesUnsubscribe = onSnapshot(q, (snapshot) => {
    const trades = [];
    snapshot.forEach(doc => {
      trades.push({ id: doc.id, data: doc.data() });
    });
    updateTradesUI(trades);
  });
}

// Update trades UI
function updateTradesUI(trades) {
  const tTr = $('#tTr');
  tTr.innerHTML = '';

  trades.forEach(trade => {
    const row = document.createElement('tr');
    row.innerHTML = `
      <td>${trade.data.date || ''}</td>
      <td>${trade.data.accountId || ''}</td>
      <td>${trade.data.instrument || ''}</td>
      <td>${trade.data.direction || ''}</td>
      <td>${trade.data.lots || ''}</td>
      <td class="${cl(trade.data.result || 0)}">${sg(trade.data.result || 0)}</td>
      <td>${trade.data.rr || ''}</td>
      <td>${trade.data.setup || ''}</td>
      <td>${trade.data.planMet || ''}</td>
      <td>${trade.data.emotion || ''}</td>
      <td>${trade.data.notes || ''}</td>
    `;
    tTr.appendChild(row);
  });
}

// Load snapshots for current user
function loadSnapshots() {
  const snapshotsRef = collection(db, 'snapshots');
  const q = query(snapshotsRef, where('accountId', '==', currentUser.uid));
  
  snapshotsUnsubscribe = onSnapshot(q, (snapshot) => {
    const snapshots = [];
    snapshot.forEach(doc => {
      snapshots.push({ id: doc.id, data: doc.data() });
    });
    updateSnapshotsUI(snapshots);
  });
}

// Update snapshots UI
function updateSnapshotsUI(snapshots) {
  const hmBody = $('#hmBody');
  hmBody.innerHTML = '';
  
  snapshots.forEach(snapshot => {
    const time = snapshot.data.timestamp || '';
    const balance = snapshot.data.balance || 0;
    const equity = snapshot.data.equity || 0;
    
    const card = document.createElement('div');
    card.className = 'card';
    card.innerHTML = `
      <div class="l">Snapshot ${snapshot.id}</div>
      <div class="v">${fmt(balance)}</div>
      <div class="d">Equité: ${fmt(equity)}</div>
      <div class="d">Heure: ${time}</div>
    `;
    hmBody.appendChild(card);
  });
}

// Initialize dashboard chart
function initDashboardChart() {
  const chartData = {
    labels: ['24h', '48h', '72h', '96h'],
    datasets: [{
      label: 'Évolution',
      data: [0, 0, 0, 0],
      borderColor: getComputedStyle(document.documentElement).getPropertyValue('--o'),
      backgroundColor: getComputedStyle(document.documentElement).getPropertyValue('--o') + '20'
    }]
  };
  
  return initChart('cEq', 'bar', chartData);
}

// Cleanup function
export function cleanup() {
  if (accountsUnsubscribe) accountsUnsubscribe();
  if (tradesUnsubscribe) tradesUnsubscribe();
  if (snapshotsUnsubscribe) snapshotsUnsubscribe();
  if (authUnsubscribe) authUnsubscribe();
  currentUser = null;
}

// Handle page visibility changes
export function setupVisibilityHandler() {
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      cleanup();
    }
  });
}