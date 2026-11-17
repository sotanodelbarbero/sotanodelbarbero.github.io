// Datos del proyecto de Supabase (Project Settings > API).
// La clave "publishable"/"anon" es pública por diseño: la seguridad la dan las reglas RLS de schema.sql.
window.BARBERIA = {
  nombre: "Sótano del Barbero",
  instagram: "https://www.instagram.com/sotanodelbarbero/",
  // Datos de la página principal (index.html). Si los dejas vacíos, esa parte no se muestra.
  direccion: "",          // ej. "Av. Juárez 123, Centro, Ciudad"
  mapa: "",               // enlace de Google Maps
  horario: [],            // ej. [["Lun a Vie", "10:00 – 20:00"], ["Sábado", "9:00 – 18:00"], ["Domingo", "Cerrado"]]
  whatsapp: "",           // WhatsApp de la barbería, 10 dígitos (ej. "5512345678"). Con él aparece «Confirmar por WhatsApp» al agendar.
  supabaseUrl: "https://iqvdfhjonrricibdwchc.supabase.co",
  supabaseKey: "sb_publishable_Tau2iEMQhp09lVaRfi4qow_bW-YRdUd",
};
