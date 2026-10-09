(function() {
  const picker = document.getElementById('user-selector');
  if (!picker) return;

  const field = document.getElementById('users');
  const input = document.getElementById('user-nickname');
  const chips = document.getElementById('selected-users');
  const list = document.getElementById('user-search-results');
  const status = document.getElementById('user-search-status');
  const minLength = Number(picker.dataset.minLength);
  const limit = Number(picker.dataset.limit);
  const selected = new Map();
  chips.querySelectorAll('[data-user-id]').forEach(function(chip) {
    selected.set(chip.dataset.userId, chip.dataset.nickname);
  });

  let timer;
  let controller;
  let revision = 0;
  let results = [];
  let activeIndex = -1;
  const prompt = 'Type at least ' + minLength + ' characters to search.';

  function closeList() {
    list.hidden = true;
    input.setAttribute('aria-expanded', 'false');
    input.removeAttribute('aria-activedescendant');
    activeIndex = -1;
  }

  function cancelSearch() {
    clearTimeout(timer);
    if (controller) controller.abort();
    revision += 1;
    closeList();
  }

  function renderChips() {
    chips.replaceChildren();
    selected.forEach(function(nickname, id) {
      const chip = document.createElement('span');
      chip.className = 'inline-flex items-center bg-gray-200 rounded-sm px-2 py-1 mr-2 mb-2';
      const label = document.createElement('span');
      label.textContent = nickname;
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'ml-2 text-gray-600';
      remove.textContent = '×';
      remove.setAttribute('aria-label', 'Remove ' + nickname);
      remove.addEventListener('click', function() {
        selected.delete(id);
        updateSelection(nickname + ' removed.');
      });
      chip.append(label, remove);
      chips.append(chip);
    });
  }

  function choose(user) {
    selected.set(user.id, user.nickname);
    updateSelection(user.nickname + ' selected.');
  }

  function updateSelection(message) {
    field.value = Array.from(selected.keys()).join(', ');
    renderChips();
    cancelSearch();
    input.value = '';
    input.focus();
    status.textContent = message + ' ' + prompt;
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

  async function search(query, searchRevision) {
    controller = new AbortController();
    status.textContent = 'Searching nicknames…';
    try {
      const url = new URL(picker.dataset.searchUrl, window.location.href);
      url.searchParams.set('q', query);
      const response = await fetch(url, {
        signal: controller.signal,
        headers: { Accept: 'application/json' },
        credentials: 'same-origin',
        cache: 'no-store'
      });
      if (!response.ok) throw new Error('Search failed');
      const data = await response.json();
      if (searchRevision !== revision) return;
      renderResults(data.users);
    } catch (error) {
      if (searchRevision !== revision || error.name === 'AbortError') return;
      closeList();
      status.textContent = 'Nickname search is unavailable. Try typing again. Your selections are preserved.';
    }
  }

  function renderResults(users) {
    results = users.filter(function(user) { return !selected.has(user.id); });
    list.replaceChildren();
    results.forEach(function(user, index) {
      const option = document.createElement('div');
      option.id = 'user-search-option-' + index;
      option.className = 'px-4 py-2 cursor-pointer hover:bg-gray-200';
      option.setAttribute('role', 'option');
      option.setAttribute('aria-selected', 'false');
      option.textContent = user.nickname;
      option.addEventListener('pointerdown', function(event) { event.preventDefault(); });
      option.addEventListener('click', function() { choose(user); });
      list.append(option);
    });
    list.hidden = results.length === 0;
    input.setAttribute('aria-expanded', String(results.length > 0));
    if (users.length === 0) {
      status.textContent = 'No matching nicknames.';
    } else if (results.length === 0) {
      status.textContent = 'Matching users are already selected.';
    } else {
      status.textContent = results.length + (results.length === 1 ? ' match.' : ' matches.') + ' Use ↑/↓ and Enter to select.';
    }
    if (users.length >= limit) status.textContent += ' Refine your nickname to narrow the results.';
  }

  function scheduleSearch() {
    cancelSearch();
    const query = input.value.trim();
    if (Array.from(query).length < minLength) {
      status.textContent = prompt;
      return;
    }
    status.textContent = 'Waiting to search…';
    const searchRevision = revision;
    timer = setTimeout(function() { search(query, searchRevision); }, 300);
  }

  input.addEventListener('input', scheduleSearch);
  input.addEventListener('focus', scheduleSearch);

  input.addEventListener('keydown', function(event) {
    if (event.key === 'Enter') {
      event.preventDefault();
      if (!list.hidden && activeIndex >= 0) choose(results[activeIndex]);
    } else if ((event.key === 'ArrowDown' || event.key === 'ArrowUp') && !list.hidden) {
      event.preventDefault();
      const next = event.key === 'ArrowDown' ? activeIndex + 1 :
        activeIndex < 0 ? results.length - 1 : activeIndex - 1;
      activate((next + results.length) % results.length);
    } else if (event.key === 'Escape') {
      cancelSearch();
      status.textContent = prompt;
    } else if (event.key === 'Tab') {
      cancelSearch();
    }
  });

  input.addEventListener('blur', function() { cancelSearch(); });
  renderChips();
  document.querySelector('label[for="users"]').htmlFor = input.id;
  field.hidden = true;
  picker.hidden = false;
})();
