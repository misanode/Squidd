(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

  const TRACKS = [
    { title: 'Ghosting', artist: 'TOMORROW X TOGETHER', art: 'url("assets/ghosting-cover.jpg")', duration: 223 },
  ];
  const now = { index: 0, elapsed: 58 };
  const MASCOT = { moving: 'assets/mascot-charizard.gif', still: 'assets/mascot-charizard-still.png' };
  new Image().src = MASCOT.still;
  const fmt = (t) => `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, '0')}`;

  const tpl = $('#squidd-widget');
  const widgets = {};

  const makeWidget = (host) => {
    const el = tpl.content.firstElementChild.cloneNode(true);
    el.dataset.layout = host.dataset.layout || 'both';
    el.dataset.appearance = host.dataset.appearance || 'light';
    el.classList.toggle('no-outline', host.dataset.outline !== 'on');
    host.append(el);
    const w = {
      el, playing: true, tucked: false, visible: false, notes: false, lastGlyph: '', particles: 0,
      render(animateArt) {
        const t = TRACKS[now.index];
        $('.track-title', el).textContent = t.title;
        $('.track-artist', el).textContent = t.artist;
        $$('.art', el).forEach((a) => {
          a.style.setProperty('--art', t.art);
          if (animateArt) { a.classList.remove('swap'); void a.offsetWidth; a.classList.add('swap'); }
        });
        this.progress();
      },
      progress() {
        const t = TRACKS[now.index];
        el.style.setProperty('--p', `${(now.elapsed / t.duration) * 100}%`);
        $('.t-elapsed', el).textContent = fmt(now.elapsed);
        $('.t-duration', el).textContent = fmt(t.duration);
      },
      setPlaying(on) {
        this.playing = on;
        el.classList.toggle('is-playing', on);
        const mascot = $('.mascot', el);
        const src = on ? MASCOT.moving : MASCOT.still;
        if (!mascot.src.endsWith(src)) mascot.src = src;
        $('.tbtn-play', el).setAttribute('aria-label', on ? 'Pause' : 'Play');
      },
      setTucked(on) { this.tucked = on; el.classList.toggle('is-tucked', on); },
    };
    const pill = $('.pill', el);
    const rim = $('.rim', el);
    const rects = $$('rect', rim);
    const sizeRim = () => {
      const width = pill.offsetWidth, height = pill.offsetHeight;
      if (!width || !height) return;
      rim.setAttribute('viewBox', `0 0 ${width} ${height}`);
      rim.setAttribute('preserveAspectRatio', 'none');
      rects.forEach((r) => {
        r.setAttribute('x', .75); r.setAttribute('y', .75);
        r.setAttribute('width', width - 1.5); r.setAttribute('height', height - 1.5);
        r.setAttribute('rx', (height - 1.5) / 2);
      });
    };
    if ('ResizeObserver' in window) new ResizeObserver(sizeRim).observe(pill);
    requestAnimationFrame(sizeRim);
    w.setPlaying(true);
    w.render(false);
    return w;
  };

  $$('[data-widget]').forEach((host) => { widgets[host.dataset.widget] = makeWidget(host); });
  ['stage', 'keys', 'light', 'dark'].forEach((k) => { if (widgets[k]) widgets[k].notes = true; });

  const all = () => Object.values(widgets);
  const renderAll = (animateArt) => all().forEach((w) => w.render(animateArt));
  const skip = (dir) => {
    now.index = (now.index + dir + TRACKS.length) % TRACKS.length;
    now.elapsed = 0;
    renderAll(true);
    announce();
  };

  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => entries.forEach((e) => {
      const w = all().find((x) => x.el.parentElement === e.target);
      if (w) w.visible = e.isIntersecting;
    }));
    $$('[data-widget]').forEach((h) => io.observe(h));
  } else all().forEach((w) => { w.visible = true; });

  setInterval(() => {
    now.elapsed += 1;
    if (now.elapsed >= TRACKS[now.index].duration) { skip(1); return; }
    all().forEach((w) => w.progress());
  }, 1000);

  const GLYPHS = ['♪', '♫', '♩', '♬'];
  const rand = (a, b) => a + Math.random() * (b - a);
  const spawnNote = (w) => {
    if (w.particles >= 8) return;
    const layer = $('.notes', w.el);
    const glass = $('.card-glass', w.el);
    const width = glass.offsetWidth, height = glass.offsetHeight;
    const choices = GLYPHS.filter((g) => g !== w.lastGlyph);
    const glyph = choices[Math.floor(Math.random() * choices.length)];
    w.lastGlyph = glyph;
    const fraction = now.elapsed / TRACKS[now.index].duration;
    const size = rand(19, 24), duration = rand(2400, 3600), rise = rand(58, 88);
    const drift = rand(9, 26) * (Math.random() < .5 ? -1 : 1), peak = rand(.75, 1);
    const n = document.createElement('span');
    n.className = 'note';
    n.textContent = glyph;
    n.style.fontSize = `${size}px`;
    n.style.left = `${48 + Math.max(0, width - 99) * fraction}px`;
    n.style.top = `${height - 40}px`;
    layer.append(n);
    w.particles++;
    const at = (p, scale, opacity) => ({
      offset: p, opacity: opacity * peak,
      transform: `translate(-50%, -50%) translate(${drift * p}px, ${-rise * p}px) rotate(${drift * .9 * p}deg) scale(${scale})`,
    });
    const anim = n.animate([
      at(0, .6, 0), at(.18, .6 + .18 / .55 * .4, 1), at(.55, 1, 1), at(.72, 1 - .17 / .45 * .08, 1), at(1, .92, 0),
    ], { duration, easing: 'linear', fill: 'forwards' });
    anim.onfinish = () => { n.remove(); w.particles--; };
  };
  if (!reduceMotion) setInterval(() => {
    all().forEach((w) => { if (w.notes && w.playing && !w.tucked && w.visible && !document.hidden) spawnNote(w); });
  }, 780);

  const stage = $('#desktop-demo');
  const statusText = $('#status-text');
  const statusButtons = $$('[data-status]');
  const thumb = $('.seg-thumb');
  let currentStatus = 'playing';
  function announce() {
    if (!statusText) return;
    const t = TRACKS[now.index];
    statusText.textContent = currentStatus === 'paused' ? `Paused ${t.title}.`
      : currentStatus === 'tucked' ? 'Player tucked away. The pill keeps glowing.'
        : `Playing ${t.title} by ${t.artist}.`;
  }
  const moveThumb = () => {
    const active = statusButtons.find((b) => b.getAttribute('aria-pressed') === 'true');
    if (!thumb || !active) return;
    thumb.style.width = `${active.offsetWidth}px`;
    thumb.style.transform = `translateX(${active.offsetLeft}px)`;
  };
  moveThumb();
  addEventListener('resize', moveThumb);
  document.fonts?.ready.then(moveThumb);

  const setStatus = (key) => {
    const w = widgets.stage;
    if (!w) return;
    currentStatus = key;
    w.setPlaying(key !== 'paused');
    w.setTucked(key === 'tucked');
    stage.dataset.state = key;
    statusButtons.forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.status === key)));
    moveThumb();
    announce();
  };

  const order = ['playing', 'paused', 'tucked'];
  let autoIndex = 0, autoTimer = null, userTookOver = false;
  const startAuto = () => {
    if (userTookOver || reduceMotion || autoTimer) return;
    autoTimer = setInterval(() => { autoIndex = (autoIndex + 1) % order.length; setStatus(order[autoIndex]); }, 4600);
  };
  const stopAuto = () => { clearInterval(autoTimer); autoTimer = null; };
  const takeOver = () => { userTookOver = true; stopAuto(); };
  statusButtons.forEach((b) => b.addEventListener('click', () => { takeOver(); setStatus(b.dataset.status); }));
  if (stage && 'IntersectionObserver' in window) {
    new IntersectionObserver(([e]) => (e.isIntersecting ? startAuto() : stopAuto()), { threshold: .4 }).observe(stage);
  }

  const flash = (btn) => { btn.classList.add('pressed'); setTimeout(() => btn.classList.remove('pressed'), 180); };
  Object.entries(widgets).forEach(([key, w]) => {
    $$('.tbtn', w.el).forEach((btn) => btn.addEventListener('click', () => {
      flash(btn);
      const cmd = btn.dataset.cmd;
      if (cmd === 'prev') skip(-1);
      else if (cmd === 'next') skip(1);
      else if (key === 'stage') { takeOver(); setStatus(w.playing ? 'paused' : 'playing'); }
      else w.setPlaying(!w.playing);
    }));
    const logo = $('.pill-logo', w.el);
    logo.addEventListener('pointerdown', () => { logo.style.transform = 'scale(.9)'; logo.style.opacity = '.7'; });
    const up = () => { logo.style.transform = ''; logo.style.opacity = ''; };
    logo.addEventListener('pointerup', up);
    logo.addEventListener('pointerleave', up);
    logo.style.cursor = 'pointer';
    logo.addEventListener('click', () => {
      if (key === 'stage') { takeOver(); setStatus(w.tucked ? (w.playing ? 'playing' : 'paused') : 'tucked'); }
      else if (key === 'keys') toggleKeys();
    });
  });

  if (stage && !reduceMotion) {
    let ticking = false;
    const update = () => {
      const r = stage.getBoundingClientRect();
      const p = Math.min(Math.max(1 - (r.top - 80) / (innerHeight * .7), 0), 1);
      stage.style.setProperty('--tilt', `${(1 - p) * 12}deg`);
      stage.style.setProperty('--scale', String(.95 + p * .05));
      ticking = false;
    };
    addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(update); } }, { passive: true });
    update();
  }

  const fitStage = () => {
    if (!stage) return;
    const width = stage.clientWidth;
    stage.style.setProperty('--s', String(matchMedia('(max-width: 720px)').matches ? Math.min(1, width / 400) : width / 1180));
  };
  if (stage) { fitStage(); new ResizeObserver(fitStage).observe(stage); }

  const clock = $('#clock');
  const tick = () => { if (clock) { const d = new Date(); clock.textContent = `${d.toLocaleDateString([], { weekday: 'short' })} ${d.toLocaleDateString([], { month: 'short', day: 'numeric' })}  ${d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}`; } };
  tick(); setInterval(tick, 15000);

  const doc = $('#doc');
  const LINES = ['Saturday', '• Farmers market before ten', '• Fix the bike chain', '• Return the library books', '• Finish chapter four (with snacks)'];
  const full = LINES.join('\n');
  const paint = (n) => {
    const text = full.slice(0, n);
    const [head, ...rest] = text.split('\n');
    doc.replaceChildren();
    const b = document.createElement('b');
    b.textContent = head;
    doc.append(b, document.createTextNode(rest.join('\n')));
    const caret = document.createElement('i');
    caret.className = 'caret';
    (rest.length ? doc : b).append(caret);
  };
  if (doc) {
    if (reduceMotion) paint(full.length);
    else {
      paint(0);
      let n = 0;
      const type = () => {
        if (n >= full.length) return;
        n++;
        paint(n);
        setTimeout(type, full[n - 1] === '\n' ? 520 : rand(35, 95));
      };
      setTimeout(type, 2600);
    }
  }

  const revealables = $$('[data-reveal]');
  if ('IntersectionObserver' in window && !reduceMotion) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('is-in'); io.unobserve(e.target); } });
    }, { rootMargin: '0px 0px -10% 0px' });
    revealables.forEach((el) => io.observe(el));
  } else revealables.forEach((el) => el.classList.add('is-in'));

  const floatGet = $('.float-get');
  const heroGet = $('#hero-get');
  if (floatGet && heroGet && 'IntersectionObserver' in window) {
    new IntersectionObserver(([entry]) => {
      const past = !entry.isIntersecting && entry.boundingClientRect.top < 0;
      floatGet.classList.toggle('is-shown', past);
      floatGet.tabIndex = past ? 0 : -1;
      floatGet.setAttribute('aria-hidden', String(!past));
    }).observe(heroGet);
  }

  $$('[data-get]').forEach((a) => a.addEventListener('click', (e) => {
    e.preventDefault();
    if (!a.classList.contains('get-button')) return;
    a.setAttribute('data-soon', '');
    clearTimeout(a._soon);
    a._soon = setTimeout(() => a.removeAttribute('data-soon'), 1800);
  }));

  const compare = $('#compare');
  const range = compare && $('.compare-range', compare);
  if (range) range.addEventListener('input', () => compare.style.setProperty('--x', `${range.value}%`));

  $$('[data-layout-pick]').forEach((b) => b.addEventListener('click', () => {
    if (!widgets.layout) return;
    widgets.layout.el.dataset.layout = b.dataset.layoutPick;
    $$('[data-layout-pick]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
  }));

  $$('[data-accent]').forEach((b) => b.addEventListener('click', () => {
    if (!widgets.colors) return;
    const [lp, lh, rim] = b.dataset.accent.split(',');
    const el = widgets.colors.el;
    el.style.setProperty('--lp', lp);
    el.style.setProperty('--lh', lh);
    el.style.setProperty('--rim-accent', rim);
    $$('[data-accent]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
  }));

  const modeToggle = $('.mode-toggle');
  if (modeToggle && stage) modeToggle.addEventListener('click', () => {
    const dark = modeToggle.getAttribute('aria-checked') !== 'true';
    modeToggle.setAttribute('aria-checked', String(dark));
    $('.mode-label', modeToggle).textContent = dark ? 'Dark' : 'Light';
    stage.dataset.mode = dark ? 'dark' : 'light';
    if (widgets.stage) widgets.stage.el.dataset.appearance = dark ? 'dark' : 'light';
  });

  const applyTouch = (b) => {
    const w = widgets.touches;
    if (!w) return;
    const on = b.getAttribute('aria-checked') === 'true';
    if (b.dataset.touch === 'outline') w.el.classList.toggle('no-outline', !on);
    else w.notes = on;
  };
  $$('[data-touch]').forEach((b) => {
    applyTouch(b);
    b.addEventListener('click', () => {
      b.setAttribute('aria-checked', String(b.getAttribute('aria-checked') !== 'true'));
      applyTouch(b);
    });
  });

  const keyButtons = $$('.keys .key');
  function toggleKeys() {
    keyButtons.forEach((k, i) => setTimeout(() => k.classList.add('pressed'), i * 40));
    setTimeout(() => keyButtons.forEach((k) => k.classList.remove('pressed')), 260);
    widgets.keys?.setTucked(!widgets.keys.tucked);
  }
  keyButtons.forEach((k) => k.addEventListener('click', toggleKeys));
  addEventListener('keydown', (e) => {
    if (e.ctrlKey && e.altKey && e.metaKey && (e.code === 'Slash' || e.key === '/')) { e.preventDefault(); toggleKeys(); }
  });

  const bigKeys = $$('.bigkey');
  if (bigKeys.length && !reduceMotion) {
    setInterval(() => {
      bigKeys.forEach((k, i) => setTimeout(() => k.classList.add('pressed'), i * 130));
      setTimeout(() => bigKeys.forEach((k) => k.classList.remove('pressed')), 900);
    }, 2800);
  }

  $$('.faq-list details').forEach((d) => {
    const summary = $('summary', d);
    const body = $('.faq-answer', d);
    summary.addEventListener('click', (e) => {
      if (reduceMotion || !body.animate) return;
      e.preventDefault();
      if (d.open) {
        const a = body.animate([{ height: `${body.offsetHeight}px`, opacity: 1 }, { height: '0px', opacity: 0 }], { duration: 260, easing: 'cubic-bezier(.22,1,.36,1)' });
        a.onfinish = () => { d.open = false; };
      } else {
        d.open = true;
        body.animate([{ height: '0px', opacity: 0 }, { height: `${body.offsetHeight}px`, opacity: 1 }], { duration: 320, easing: 'cubic-bezier(.22,1,.36,1)' });
      }
    });
  });
})();
