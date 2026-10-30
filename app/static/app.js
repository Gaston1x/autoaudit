// AutoAudit - comportamiento de la interfaz (sin dependencias).
(function () {
  // Números con separador de miles: <span data-contar="1234">
  document.querySelectorAll("[data-contar]").forEach((el) => {
    el.textContent = (Number(el.dataset.contar) || 0).toLocaleString("es-GT");
  });

  // Resaltado sencillo de SQL en <pre class="sql">.
  const palabras = /\b(CREATE|OR|REPLACE|FUNCTION|RETURNS|TRIGGER|LANGUAGE|SECURITY|DEFINER|SET|AS|DECLARE|BEGIN|END|IF|THEN|ELSIF|ELSE|RETURN|NULL|INSERT|INTO|VALUES|UPDATE|DELETE|SELECT|FROM|WHERE|NOT|IS|DISTINCT|AFTER|BEFORE|ON|FOR|EACH|ROW|EXECUTE|DROP|EXISTS|OF|AND|EXCEPTION|WHEN|OTHERS|RETURNING)\b/g;
  document.querySelectorAll("pre.sql").forEach((pre) => {
    const esc = pre.textContent.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    pre.innerHTML = esc
      .split("\n")
      .map((linea) => {
        const i = linea.indexOf("--");
        const codigo = i >= 0 ? linea.slice(0, i) : linea;
        const coment = i >= 0 ? `<span class="cm">${linea.slice(i)}</span>` : "";
        return codigo.replace(/'[^']*'/g, (m) => `<span class="st">${m}</span>`).replace(palabras, '<span class="kw">$1</span>') + coment;
      })
      .join("\n");
  });

  // Filtro rápido de tablas: <input data-filtro="#idTabla">
  document.querySelectorAll("[data-filtro]").forEach((inp) => {
    const tabla = document.querySelector(inp.dataset.filtro);
    inp.addEventListener("input", () => {
      const q = inp.value.toLowerCase();
      tabla.querySelectorAll("tbody tr").forEach((tr) => (tr.style.display = tr.textContent.toLowerCase().includes(q) ? "" : "none"));
    });
  });
})();
