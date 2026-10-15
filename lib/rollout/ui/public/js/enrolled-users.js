(function() {
  const section = document.getElementById('enrolled-users');
  if (!section) return;

  const rows = document.getElementById('enrolled-users-rows');
  const addField = document.getElementById('users-to-add');
  const changeInputs = document.getElementById('user-change-inputs');
  const pageField = document.getElementById('users-page');
  const status = document.getElementById('enrollment-status');
  const pending = document.getElementById('pending-user-changes');
  const details = document.getElementById('pending-user-details');
  const review = document.getElementById('pending-user-review');
  const reviewButton = document.getElementById('review-user-changes');
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
    button.setAttribute('aria-label', (removals.has(user.id) ? 'Undo removal of ' : 'Remove ') + user.nickname + ' (#' + user.id + ')');
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

  function focusAddField() {
    (picker ? document.getElementById('user-nickname') : addField).focus();
  }

  function closeReview(restoreFocus) {
    review.hidden = true;
    reviewButton.setAttribute('aria-expanded', 'false');
    if (restoreFocus && !pending.hidden) reviewButton.focus();
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
    document.getElementById('pending-user-slot').hidden = pending.hidden;
    if (pending.hidden) closeReview(false);
    const counts = [];
    if (additions.size) counts.push(additions.size + (additions.size === 1 ? ' addition' : ' additions'));
    if (removals.size) counts.push(removals.size + (removals.size === 1 ? ' removal' : ' removals'));
    const summary = document.getElementById('pending-user-summary');
    summary.textContent = counts.length ? counts.join(' · ') + ' pending' : '';
    summary.title = summary.textContent;
    details.replaceChildren();
    [additions, removals].forEach(function(changes, index) {
      changes.forEach(function(nickname, id) {
        const item = document.createElement('li');
        const label = document.createElement('span');
        label.textContent = (index === 0 ? '+ ' : '− ') + nickname + ' (#' + id + ')';
        const undo = document.createElement('button');
        undo.type = 'button';
        undo.className = 'text-gray-600 hover:underline';
        undo.textContent = 'Undo';
        undo.setAttribute('aria-label', 'Undo ' + (index === 0 ? 'addition' : 'removal') + ' of ' + nickname + ' (#' + id + ')');
        undo.addEventListener('click', function() {
          const position = Array.from(details.querySelectorAll('button')).indexOf(undo);
          changes.delete(id);
          if (!picker) addField.value = Array.from(additions.keys()).join(', ');
          renderPending();
          const buttons = details.querySelectorAll('button');
          if (buttons.length) buttons[Math.min(position, buttons.length - 1)].focus();
          else focusAddField();
        });
        item.append(label, undo);
        details.append(item);
      });
    });
    enhanceRows();
  }

  function updateNavigation() {
    pageField.value = String(currentPage);
    document.getElementById('enrolled-user-count').textContent = String(total);
    section.querySelectorAll('[data-user-page-number]').forEach(function(label) {
      label.textContent = 'Page ' + currentPage + ' of ' + totalPages;
    });
    section.querySelectorAll('[data-user-page-direction]').forEach(function(link) {
      const previous = link.dataset.userPageDirection === 'previous';
      const page = previous ? Math.max(currentPage - 1, 1) : Math.min(currentPage + 1, totalPages);
      const disabled = previous ? currentPage === 1 : currentPage === totalPages;
      const url = new URL(document.getElementById('updateFormSubmit').action);
      url.searchParams.set('page', page);
      if (disabled) link.removeAttribute('href');
      else link.href = url.toString();
      link.dataset.page = String(page);
      link.setAttribute('aria-disabled', String(disabled));
      link.tabIndex = disabled ? -1 : 0;
    });
  }

  function showPageStart(direction) {
    const navigation = document.getElementById('enrolled-users-pagination');
    const preferred = navigation.querySelector('[data-user-page-direction="' + direction + '"]');
    const target = preferred && preferred.getAttribute('aria-disabled') !== 'true' ? preferred : navigation.querySelector('[aria-disabled="false"]') || document.getElementById('enrolled-users-table');
    target.focus({ preventScroll: true });
    const box = navigation.getBoundingClientRect();
    if (box.top < 0 || box.bottom + 80 > window.innerHeight) navigation.scrollIntoView({ block: 'start' });
  }

  async function loadPage(page, direction) {
    if (pageController) pageController.abort();
    const revision = ++pageRevision;
    pageController = new AbortController();
    status.textContent = 'Loading enrolled users…';
    try {
      const url = new URL(section.dataset.usersUrl, window.location.href);
      url.searchParams.set('page', page);
      const response = await fetch(url, { headers: { Accept: 'application/json' }, credentials: 'same-origin', cache: 'no-store', signal: pageController.signal });
      if (!response.ok) throw new Error('Enrollment page unavailable');
      const data = await response.json();
      if (revision !== pageRevision) return;
      if (!checkVersion(data)) return;
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
      status.textContent = data.lookup_failed ? 'Nicknames could not be loaded. Their user IDs are preserved.' : '';
      showPageStart(direction);
    } catch (error) {
      if (revision !== pageRevision || error.name === 'AbortError') return;
      status.textContent = 'The enrollment list is temporarily unavailable. Your pending changes are preserved. Try again.';
    }
  }

  section.querySelectorAll('[data-user-page-direction]').forEach(function(link) {
    link.addEventListener('click', function(event) {
      event.preventDefault();
      if (this.getAttribute('aria-disabled') !== 'true') loadPage(Number(this.dataset.page), this.dataset.userPageDirection);
    });
  });
  reviewButton.addEventListener('click', function() {
    if (!review.hidden) { closeReview(true); return; }
    review.hidden = false;
    reviewButton.setAttribute('aria-expanded', 'true');
    (details.querySelector('button') || document.getElementById('close-user-review')).focus();
  });
  document.getElementById('close-user-review').addEventListener('click', function() { closeReview(true); });
  document.addEventListener('pointerdown', function(event) {
    if (!pending.contains(event.target)) closeReview(false);
  });
  pending.addEventListener('focusout', function(event) {
    if (event.relatedTarget && !pending.contains(event.relatedTarget)) closeReview(false);
  });
  document.addEventListener('keydown', function(event) {
    if (event.key === 'Escape' && !review.hidden) {
      event.preventDefault();
      closeReview(true);
    }
  });
  document.getElementById('discard-user-changes').addEventListener('click', function() {
    additions.clear();
    removals.clear();
    addField.value = '';
    renderPending();
    focusAddField();
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
  const dropdown = document.getElementById('user-search-dropdown');
  const list = document.getElementById('user-search-results');
  const searchStatus = document.getElementById('user-search-status');
  const resultStatus = document.getElementById('user-search-result-status');
  const minLength = Number(picker.dataset.minLength);
  const limit = Number(picker.dataset.limit);
  let timer;
  let searchController;
  let searchRevision = 0;
  let results = [];
  let activeIndex = -1;

  function closeList() {
    dropdown.hidden = true;
    list.hidden = true;
    resultStatus.textContent = '';
    input.setAttribute('aria-expanded', 'false');
    input.removeAttribute('aria-activedescendant');
    activeIndex = -1;
  }
  function cancelSearch() {
    clearTimeout(timer);
    if (searchController) searchController.abort();
    searchRevision++;
    closeList();
    searchStatus.textContent = '';
    searchStatus.title = '';
  }
  function showSearchMessage(message) {
    closeList();
    searchStatus.textContent = '';
    resultStatus.textContent = message;
    dropdown.hidden = false;
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
    searchStatus.textContent = user.nickname + ' selected.';
    searchStatus.title = searchStatus.textContent;
  }
  function activate(index) {
    activeIndex = index;
    Array.from(list.children).forEach(function(option, i) {
      option.setAttribute('aria-selected', String(i === index));
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
      if (!checkVersion(data)) { showSearchMessage(conflict); return; }
      results = data.users;
      list.replaceChildren();
      results.forEach(function(user, index) {
        const option = document.createElement('div');
        option.id = 'user-search-option-' + index;
        option.className = 'px-4 py-2 cursor-pointer flex items-center justify-between';
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
      dropdown.hidden = results.length === 0;
      input.setAttribute('aria-expanded', String(results.length > 0));
      searchStatus.textContent = results.length ? '' : 'No matching nicknames.';
      resultStatus.textContent = results.length ? results.length + (results.length === 1 ? ' match.' : ' matches.') + ' Use ↑/↓ and Enter to select.' : '';
      if (results.length >= limit) resultStatus.textContent += ' Refine your nickname to narrow the results.';
    } catch (error) {
      if (revision !== searchRevision || error.name === 'AbortError') return;
      showSearchMessage('Nickname search is unavailable. Your pending changes are preserved. Try again.');
    }
  }
  function scheduleSearch() {
    cancelSearch();
    const query = input.value.trim();
    if (Array.from(query).length < minLength) {
      searchStatus.textContent = query ? 'At least ' + minLength + ' characters' : '';
      return;
    }
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
