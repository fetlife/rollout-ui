(function() {
  const section = document.getElementById('enrolled-users');
  if (!section) return;

  const rows = document.getElementById('enrolled-users-rows');
  const addField = document.getElementById('users-to-add');
  const changeInputs = document.getElementById('user-change-inputs');
  const pageField = document.getElementById('users-page');
  const sizeField = document.getElementById('users-per-page');
  const status = document.getElementById('enrollment-status');
  const pending = document.getElementById('pending-user-changes');
  const details = document.getElementById('pending-user-details');
  const version = document.querySelector('#updateFormSubmit [name="feature_version"]').value;
  const picker = document.getElementById('user-selector');
  const additions = new Map();
  const removals = new Map();
  const knownMembers = new Map();
  let currentPage = Number(section.dataset.page);
  let perPage = Number(section.dataset.perPage);
  let total = Number(section.dataset.total);
  let totalPages = Number(section.dataset.totalPages);
  let pageRevision = 0;
  let pageController;
  const conflict = 'This rollout changed while you were editing. Your pending changes are preserved. Reload the page to review the latest state before updating.';

  function checkVersion(data) {
    if (data.feature_version !== version) {
      status.textContent = conflict;
      return false;
    }
    return true;
  }

  function removeButton(row, user) {
    const cell = row.lastElementChild;
    let button = cell.querySelector('button');
    if (!button) {
      button = document.createElement('button');
      button.type = 'button';
      button.className = 'text-xs text-gray-600 hover:underline';
      button.addEventListener('click', function() {
        if (removals.has(user.id)) removals.delete(user.id);
        else removals.set(user.id, user.nickname);
        renderPending();
      });
      cell.replaceChildren(button);
    }
    button.textContent = removals.has(user.id) ? 'Undo' : 'Remove';
    button.setAttribute('aria-label', (removals.has(user.id) ? 'Undo removal of ' : 'Remove ') + user.nickname);
    row.firstElementChild.classList.toggle('line-through', removals.has(user.id));
    row.firstElementChild.classList.toggle('text-gray-400', removals.has(user.id));
  }

  function enhanceRows() {
    rows.querySelectorAll('[data-user-id]').forEach(function(row) {
      const user = { id: row.dataset.userId, nickname: row.dataset.nickname };
      knownMembers.set(user.id, user.nickname);
      removeButton(row, user);
    });
  }

  function renderPending() {
    if (picker) addField.value = Array.from(additions.keys()).join(', ');
    changeInputs.replaceChildren();
    if (removals.size) {
      const input = document.createElement('input');
      input.type = 'hidden';
      input.name = 'users_to_remove';
      input.value = Array.from(removals.keys()).join(', ');
      changeInputs.append(input);
    }
    pending.hidden = additions.size + removals.size === 0;
    document.getElementById('pending-user-summary').textContent = 'Pending changes · ' + additions.size + ' to add · ' + removals.size + ' to remove';
    details.replaceChildren();
    [additions, removals].forEach(function(changes, index) {
      changes.forEach(function(nickname, id) {
        const item = document.createElement('li');
        const label = document.createElement('span');
        label.textContent = (index === 0 ? '+ ' : '− ') + nickname + ' (#' + id + ') ';
        const undo = document.createElement('button');
        undo.type = 'button';
        undo.className = 'text-gray-600 hover:underline';
        undo.textContent = 'Undo';
        undo.setAttribute('aria-label', 'Undo ' + (index === 0 ? 'addition' : 'removal') + ' of ' + nickname);
        undo.addEventListener('click', function() {
          changes.delete(id);
          if (!picker) addField.value = Array.from(additions.keys()).join(', ');
          renderPending();
          (details.querySelector('button') || (picker ? document.getElementById('user-nickname') : addField)).focus();
        });
        item.append(label, undo);
        details.append(item);
      });
    });
    enhanceRows();
  }

  function updateNavigation() {
    pageField.value = String(currentPage);
    sizeField.value = String(perPage);
    document.getElementById('enrolled-user-count').textContent = String(total);
    document.getElementById('users-range').textContent = 'Showing ' + (total ? (currentPage - 1) * perPage + 1 : 0) + '–' + Math.min(currentPage * perPage, total) + ' of ' + total + ' enrolled users';
    document.getElementById('users-page-number').textContent = 'Page ' + currentPage + ' of ' + totalPages;
    [['users-previous', Math.max(currentPage - 1, 1), currentPage === 1], ['users-next', Math.min(currentPage + 1, totalPages), currentPage === totalPages]].forEach(function(item) {
      const link = document.getElementById(item[0]);
      const url = new URL(document.getElementById('updateFormSubmit').action);
      url.searchParams.set('page', item[1]);
      url.searchParams.set('per_page', perPage);
      link.href = url.toString();
      link.dataset.page = String(item[1]);
      link.setAttribute('aria-disabled', String(item[2]));
      link.classList.toggle('opacity-50', item[2]);
      link.tabIndex = item[2] ? -1 : 0;
    });
  }

  async function loadPage(page, size) {
    if (pageController) pageController.abort();
    const revision = ++pageRevision;
    pageController = new AbortController();
    status.textContent = 'Loading enrolled users…';
    try {
      const url = new URL(section.dataset.usersUrl, window.location.href);
      url.searchParams.set('page', page);
      url.searchParams.set('per_page', size);
      const response = await fetch(url, { headers: { Accept: 'application/json' }, credentials: 'same-origin', cache: 'no-store', signal: pageController.signal });
      if (!response.ok) throw new Error('Enrollment page unavailable');
      const data = await response.json();
      if (revision !== pageRevision) return;
      if (!checkVersion(data)) { sizeField.value = String(perPage); return; }
      currentPage = data.page;
      perPage = data.per_page;
      total = data.total;
      totalPages = data.total_pages;
      rows.replaceChildren();
      data.users.forEach(function(user) {
        const row = document.createElement('tr');
        row.className = 'border-b border-gray-200';
        row.dataset.userId = user.id;
        row.dataset.nickname = user.nickname;
        const nickname = document.createElement('td');
        nickname.className = 'px-3 py-2 break-all';
        nickname.textContent = user.nickname;
        const id = document.createElement('td');
        id.className = 'px-3 py-2 text-xs text-gray-500';
        id.textContent = '#' + user.id;
        const action = document.createElement('td');
        action.className = 'px-3 py-2 text-right';
        row.append(nickname, id, action);
        rows.append(row);
      });
      if (!data.users.length) {
        const row = document.createElement('tr');
        const cell = document.createElement('td');
        cell.colSpan = 3;
        cell.className = 'px-3 py-3 text-gray-500';
        cell.textContent = 'No explicitly enrolled users.';
        row.append(cell);
        rows.append(row);
      }
      enhanceRows();
      updateNavigation();
      status.textContent = document.getElementById('users-range').textContent + '. Page ' + currentPage + ' of ' + totalPages + '.';
      if (data.lookup_failed) status.textContent += ' Nicknames could not be loaded. Their user IDs are preserved.';
    } catch (error) {
      if (revision !== pageRevision || error.name === 'AbortError') return;
      sizeField.value = String(perPage);
      status.textContent = 'The enrollment list is temporarily unavailable. Your pending changes are preserved. Try again.';
    }
  }

  ['users-previous', 'users-next'].forEach(function(id) {
    document.getElementById(id).addEventListener('click', function(event) {
      event.preventDefault();
      if (this.getAttribute('aria-disabled') !== 'true') loadPage(Number(this.dataset.page), perPage);
    });
  });
  sizeField.addEventListener('change', function() { loadPage(1, Number(this.value)); });
  document.getElementById('discard-user-changes').addEventListener('click', function() {
    additions.clear();
    removals.clear();
    addField.value = '';
    renderPending();
    (picker ? document.getElementById('user-nickname') : addField).focus();
  });
  if (!picker) {
    addField.addEventListener('input', function() {
      additions.clear();
      this.value.split(',').map(function(id) { return id.trim(); }).filter(Boolean).forEach(function(id) {
        if (!knownMembers.has(id)) additions.set(id, 'User');
      });
      renderPending();
    });
  }
  enhanceRows();
  updateNavigation();

  if (!picker) return;
  const input = document.getElementById('user-nickname');
  const list = document.getElementById('user-search-results');
  const searchStatus = document.getElementById('user-search-status');
  const minLength = Number(picker.dataset.minLength);
  const limit = Number(picker.dataset.limit);
  const prompt = 'Type at least ' + minLength + ' characters to search. Already-enrolled users are identified across all pages.';
  let timer;
  let searchController;
  let searchRevision = 0;
  let results = [];
  let activeIndex = -1;

  function closeList() {
    list.hidden = true;
    input.setAttribute('aria-expanded', 'false');
    input.removeAttribute('aria-activedescendant');
    activeIndex = -1;
  }
  function cancelSearch() {
    clearTimeout(timer);
    if (searchController) searchController.abort();
    searchRevision++;
    closeList();
  }
  function choose(user) {
    if (user.enrolled) {
      if (!removals.has(user.id)) return;
      removals.delete(user.id);
    } else {
      if (additions.has(user.id)) return;
      additions.set(user.id, user.nickname);
    }
    renderPending();
    cancelSearch();
    input.value = '';
    input.focus();
    searchStatus.textContent = user.nickname + ' selected. ' + prompt;
  }
  function activate(index) {
    activeIndex = index;
    Array.from(list.children).forEach(function(option, i) {
      option.setAttribute('aria-selected', String(i === index));
      option.classList.toggle('bg-gray-200', i === index);
    });
    const option = list.children[index];
    if (option) {
      input.setAttribute('aria-activedescendant', option.id);
      option.scrollIntoView({ block: 'nearest' });
    }
  }
  async function search(query, revision) {
    searchController = new AbortController();
    searchStatus.textContent = 'Searching nicknames…';
    try {
      const url = new URL(picker.dataset.searchUrl, window.location.href);
      url.searchParams.set('q', query);
      const response = await fetch(url, { signal: searchController.signal, headers: { Accept: 'application/json' }, credentials: 'same-origin', cache: 'no-store' });
      if (!response.ok) throw new Error('Search unavailable');
      const data = await response.json();
      if (revision !== searchRevision) return;
      if (!checkVersion(data)) { closeList(); searchStatus.textContent = conflict; return; }
      results = data.users;
      list.replaceChildren();
      results.forEach(function(user, index) {
        const option = document.createElement('div');
        option.id = 'user-search-option-' + index;
        option.className = 'px-4 py-2 cursor-pointer hover:bg-gray-200 flex items-center justify-between';
        const disabled = (user.enrolled && !removals.has(user.id)) || additions.has(user.id);
        option.setAttribute('role', 'option');
        option.setAttribute('aria-selected', 'false');
        option.setAttribute('aria-disabled', String(disabled));
        const nickname = document.createElement('span');
        nickname.textContent = user.nickname;
        const note = document.createElement('span');
        note.className = 'text-xs text-gray-500 ml-2';
        note.textContent = user.enrolled ? removals.has(user.id) ? 'Undo removal' : 'Already enrolled' : additions.has(user.id) ? 'Pending addition' : 'Add';
        option.append(nickname, note);
        option.addEventListener('pointerdown', function(event) { event.preventDefault(); });
        option.addEventListener('click', function() { choose(user); });
        list.append(option);
      });
      list.hidden = results.length === 0;
      input.setAttribute('aria-expanded', String(results.length > 0));
      searchStatus.textContent = results.length ? results.length + ' matches. Use ↑/↓ and Enter to select.' : 'No matching nicknames.';
      if (results.length >= limit) searchStatus.textContent += ' Refine your nickname to narrow the results.';
    } catch (error) {
      if (revision !== searchRevision || error.name === 'AbortError') return;
      closeList();
      searchStatus.textContent = 'Nickname search is unavailable. Your pending changes are preserved. Try again.';
    }
  }
  function scheduleSearch() {
    cancelSearch();
    const query = input.value.trim();
    if (Array.from(query).length < minLength) { searchStatus.textContent = prompt; return; }
    searchStatus.textContent = 'Waiting to search…';
    const revision = searchRevision;
    timer = setTimeout(function() { search(query, revision); }, 300);
  }
  input.addEventListener('input', scheduleSearch);
  input.addEventListener('focus', scheduleSearch);
  input.addEventListener('blur', cancelSearch);
  input.addEventListener('keydown', function(event) {
    if (event.key === 'Enter') { event.preventDefault(); if (!list.hidden && activeIndex >= 0) choose(results[activeIndex]); }
    else if ((event.key === 'ArrowDown' || event.key === 'ArrowUp') && !list.hidden) {
      event.preventDefault();
      const direction = event.key === 'ArrowDown' ? 1 : -1;
      let next = activeIndex < 0 ? direction === 1 ? -1 : 0 : activeIndex;
      for (let i = 0; i < results.length; i++) {
        next = (next + direction + results.length) % results.length;
        if (list.children[next].getAttribute('aria-disabled') !== 'true') { activate(next); break; }
      }
    } else if (event.key === 'Escape' || event.key === 'Tab') cancelSearch();
  });
  document.getElementById('user-id-addition').hidden = true;
  picker.hidden = false;
})();
