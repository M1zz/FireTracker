// 퇴사각 웹 데모: 앱의 '언제 그만둘 수 있을까요?' 첫 계산을 브라우저에서 그대로 해 본다.
// 규칙은 앱과 같다 — 목표 = 한 해 생활비 ÷ 안전 인출률(FireSettings 기본 4%),
// 매달 (순자산 × (1 + 연 수익률/12) + 매달 모으는 돈) 을 목표에 닿을 때까지 (FireEngine.yearsToFire, 기본 5% · 80년 한도).
(() => {
  const root = document.getElementById("demo");
  if (!root) return;
  const T = JSON.parse(root.dataset.text);
  const lang = document.documentElement.lang;
  const SWR = 0.04, RETURN = 0.05, CAP_YEARS = 80;
  const fill = (s, v) => s.replace(/\{(\w+)\}/g, (_, k) => v[k]);

  // 금액 표기: 한국어는 앱처럼 억/만, 다른 언어는 앱처럼 그 나라 말의 큰 수 표기(1.2M, 5.2億).
  function amount(v) {
    if (lang === "ko") {
      const eok = Math.floor(v / 1e8), man = Math.floor((v % 1e8) / 1e4);
      const n = v >= 1e8 ? (man ? `${eok.toLocaleString()}억 ${man.toLocaleString()}만` : `${eok.toLocaleString()}억`)
        : v >= 1e4 ? `${man.toLocaleString()}만` : Math.round(v).toLocaleString();
      return fill(T.money, { n });
    }
    const n = v < 10000 ? Math.round(v).toLocaleString(lang)
      : new Intl.NumberFormat(lang, { notation: "compact", maximumSignificantDigits: 4 }).format(v);
    return fill(T.money, { n });
  }

  // FireEngine.yearsToFire 를 그대로 옮겼다.
  function yearsToFire(worth, goal, save) {
    if (worth >= goal) return 0;
    const r = RETURN / 12;
    let balance = worth, months = 0;
    while (balance < goal && months < CAP_YEARS * 12) {
      balance = balance * (1 + r) + save;
      months++;
    }
    return months >= CAP_YEARS * 12 ? null : months / 12;
  }
  // 단위 글은 한 가지이거나 [하나일 때, 여럿일 때] 두 가지다(1 año · 2 años).
  const plural = new Intl.PluralRules(lang);
  const unit = (t, n) => fill(Array.isArray(t) ? t[plural.select(n) === "one" ? 0 : 1] : t, { n });
  function span(y) {
    const whole = Math.floor(y), m = Math.floor((y - whole) * 12);
    if (!whole) return unit(T.months, m);
    if (!m) return unit(T.years, whole);
    return fill(T.yearsMonths, { y: unit(T.years, whole), m: unit(T.months, m) });
  }

  const fields = [
    ["spend", T.spend, ...T.scale.spend],
    ["worth", T.worth, ...T.scale.worth],
    ["save", T.save, ...T.scale.save],
    ["age", T.age, 20, 65, 1, 35]
  ];
  root.innerHTML = `
    <div class="fire-inputs">
      ${fields.map(([k, label, min, max, step, value]) => `
        <label class="fire-field">
          <span class="fire-label">${label}<output data-out="${k}"></output></span>
          <input type="range" data-k="${k}" min="${min}" max="${max}" step="${step}" value="${value}">
        </label>`).join("")}
    </div>
    <div class="fire-result" aria-live="polite">
      <p class="fire-now">${T.now}</p>
      <p class="fire-date"></p>
      <p class="fire-when"></p>
      <div class="fire-bar" aria-hidden="true"><i></i></div>
      <dl class="fire-rows">
        <div><dt>${T.progress}</dt><dd data-r="progress"></dd></div>
        <div><dt>${T.target}</dt><dd data-r="target"></dd></div>
      </dl>
      <p class="muted small fire-note">${T.note}</p>
    </div>`;

  const $ = s => root.querySelector(s);
  const inputs = [...root.querySelectorAll("input")];
  const dateEl = $(".fire-date"), whenEl = $(".fire-when"), bar = $(".fire-bar i");
  const monthFmt = new Intl.DateTimeFormat(lang, { year: "numeric", month: "long" });

  function render() {
    const v = Object.fromEntries(inputs.map(i => [i.dataset.k, +i.value]));
    for (const i of inputs) {
      const text = i.dataset.k === "age" ? fill(T.ageUnit, { n: v.age }) : amount(v[i.dataset.k]);
      root.querySelector(`[data-out="${i.dataset.k}"]`).textContent = text;
      i.setAttribute("aria-valuetext", text);
      i.style.setProperty("--fill", `${(i.value - i.min) / (i.max - i.min) * 100}%`);
    }
    const goal = v.spend * 12 / SWR;
    const years = yearsToFire(v.worth, goal, v.save);
    const progress = Math.max(0, v.worth) / goal;
    root.classList.toggle("never", years === null);
    if (years === null) {
      dateEl.textContent = T.never;
      whenEl.textContent = T.neverText;
    } else if (years < 1 / 12) {
      dateEl.textContent = T.done;
      whenEl.textContent = "";
    } else {
      const d = new Date();
      d.setDate(1);
      d.setMonth(d.getMonth() + Math.round(years * 12));
      dateEl.textContent = monthFmt.format(d);
      whenEl.textContent = fill(T.quit, { t: span(years), age: v.age + Math.floor(years) });
    }
    bar.style.width = `${Math.min(1, progress) * 100}%`;
    $('[data-r="progress"]').textContent = new Intl.NumberFormat(lang, { style: "percent", maximumFractionDigits: 1 }).format(progress);
    $('[data-r="target"]').textContent = amount(goal);
  }

  root.addEventListener("input", render);
  render();
})();
