# Barbería: registro por QR y corte de caja

**Página publicada:** https://sotanodelbarbero.github.io/ (la dirección vieja nutrementeycuerpo.github.io/sotano-del-barbero redirige aquí)
- Clientes: `…/turno.html` (tomar turno) y `…/cita.html` (agendar cita)
- Personal: `…/panel.html`
- QR para imprimir: `…/qr.html`

Para publicar cambios: guarda los archivos y ejecuta en esta carpeta
`git add -A && git commit -m "qué cambiaste" && git push`. GitHub actualiza la página en 1 o 2 minutos.

| Archivo | Para qué sirve |
|---|---|
| `index.html` | Página principal del negocio: servicios y precios, cómo funciona, horario y el botón **Obtén una cita**. |
| `turno.html` | Página que abre el QR (y el botón de la página principal). El cliente pone su nombre, elige el servicio y recibe su número de turno. |
| `cita.html` | **Agendar cita**: el cliente elige servicio, barbero (opcional), día y hora (cada 30 min) y puede cancelar o agregarla a su calendario. |
| `cliente.css` | Estilo compartido de `turno.html` y `cita.html`. |
| `panel.html` | Panel del personal (con contraseña): cola del día, cobros y corte de caja. |
| `qr.html` | Genera el QR para imprimirlo y pegarlo en la entrada. |
| `supabase/schema.sql` | Tablas, reglas de seguridad y servicios de ejemplo. |
| `supabase/06_productos.sql` | Productos (pomadas, ceras…): venta e inventario. |
| `supabase/07_citas.sql` | Citas con día y hora, y el horario de la barbería. |
| `supabase/08_panel.sql` | Bloqueos (vacaciones, comida, barbero que no viene), citas desde el panel y mover citas. |
| `supabase/functions/equipo/index.ts` | Función de Supabase para crear cuentas del equipo y cambiar contraseñas (ver **Equipo** abajo). |
| `supabase/09_calendario.sql` | Calendario de apertura: horario distinto o cerrado en días específicos. |
| `supabase/11_llegada.sql` | El cliente con cita avisa «Ya llegué» desde su celular o con el QR y entra a la fila con prioridad. |
| `supabase/12_turnos.sql` | Turno de cada barbero (por ejemplo, uno en la mañana y otro en la tarde). Las citas solo se apartan cuando hay un barbero de turno. |
| `supabase/13_turno_dia.sql` | Quién trabaja en un día específico: al darle horario a un día en el calendario, se elige quién viene y de qué hora a qué hora. |
| `supabase/14_tiempo_real.sql` | Todo en tiempo real: el panel escucha precios, barberos, horario, turnos y caja; las páginas de los clientes reciben un aviso público (sin datos personales) y se actualizan al momento. |
| `supabase/15_notificaciones.sql` | Avisos al celular de los barberos: cuando les agendan, cancelan o mueven una cita, aunque tengan el panel cerrado. |
| `supabase/functions/avisos/index.ts` | Función de Supabase que manda esos avisos (ver **Avisos al celular** abajo). |
| `sw.js`, `manifest.webmanifest`, `icono-*.png` | Permiten recibir avisos y agregar el panel a la pantalla de inicio del celular. |
| `supabase/10_equipo.sql` | Guarda la comisión de cada cobro (cambiar el % no altera lo ya cobrado) y la hora en que empezó cada corte. |
| `pruebas/` | Pruebas de los casos de uso de la base de datos (`cd pruebas && npm install && npm test`). No tocan tu Supabase. |
| `config.js` | URL y clave del proyecto de Supabase, y la dirección, horario y WhatsApp que se ven en la página principal. |

## Cómo ponerlo en marcha
1. Crea un proyecto en Supabase y en el **SQL Editor** ejecuta `supabase/schema.sql`. Después ejecuta `supabase/03_roles.sql`, cambiando antes `CORREO-DE-ALEJANDRO` por su correo. Ese archivo crea los roles: admin (Alejandro), barbero y cliente (QR, sin cuenta). Al final ejecuta `supabase/04_admin.sql`, que agrega comisiones, gastos, cierre de caja y el resumen de clientes, después `supabase/05_cliente.sql`, que permite al cliente seguir su turno en vivo, después `supabase/06_productos.sql`, que agrega la venta e inventario de productos (pomadas, ceras, etc.), después `supabase/07_citas.sql`, que activa las citas con día y hora, después `supabase/08_panel.sql`, que agrega los bloqueos de agenda y las citas desde el panel, después `supabase/09_calendario.sql`, que activa el calendario de apertura, después `supabase/10_equipo.sql`, que congela la comisión de cada cobro, después `supabase/11_llegada.sql`, para que el cliente con cita avise que llegó, después `supabase/12_turnos.sql`, que agrega el turno de cada barbero, después `supabase/13_turno_dia.sql`, para elegir quién trabaja en un día específico, después `supabase/14_tiempo_real.sql`, para que todo se actualice en tiempo real, y al final `supabase/15_notificaciones.sql`, para los avisos al celular (ver **Avisos al celular**).
2. En **Project Settings > API**, copia la URL y la clave *publishable/anon* y pégalas en `config.js`.
3. En **Authentication > Users > Add user**, crea solo el usuario de Alejandro. Las cuentas de los barberos se crean desde el panel, en **Equipo** (ver abajo).
4. Publica la carpeta en un hosting estático (Netlify, Vercel o GitHub Pages) para que el QR funcione desde cualquier celular.
5. Abre `panel.html`, agrega los barberos en **Ajustes**, ajusta los precios e imprime el QR.

## Cómo se usa en el día
1. El cliente escanea el QR. Antes de registrarse ve cuánta gente hay y cuánto tendría que esperar. Se registra y se queda en la pantalla de su turno:
   - Ve cuántas personas hay antes que él y los minutos aproximados.
   - Cuando le toca, su celular vibra y suena.
   - Puede cancelar su turno si se tiene que ir.
2. En el panel aparece al instante, en **Hoy**.
3. El barbero toca **Atender** y luego **Cobrar** (monto, propina y si pagó en efectivo, con tarjeta o por transferencia).
4. Al cerrar, Alejandro abre **Corte**:
   - Captura el fondo inicial y los gastos del día.
   - El sistema calcula cuánto efectivo debe haber en la caja. Alejandro escribe lo que contó y la diferencia sale sola.
   - Abajo aparece cuánto hay que pagarle a cada barbero (comisión más propinas).
   - Al final da clic en **Cerrar caja del día**.
   - **Pasar libreta** (botón arriba en Caja): para registrar cortes de días anteriores apuntados en papel. Elige el día y el barbero y toca el servicio una vez por cada corte (sale con su precio; el monto y la propina se pueden cambiar). Avisa si ese barbero ya tiene cortes ese día para no pasarlos dos veces. Se guardan como cobros normales de ese día (caja, comisiones y reportes) a nombre de «Cliente de libreta», que no aparece en **Clientes**. Si te equivocas, se borran desde **Detalle de cobros** de ese día.
5. En **Clientes** ve a todos los que han venido: cuántas veces vino cada uno, cuánto ha gastado y quién ya no ha regresado. Tiene un botón para mandarles WhatsApp.
6. **Inicio**: al entrar al panel se ve el resumen del día (ventas contra ayer, atendidos, en espera, citas), la gráfica de la semana, las próximas citas y alertas: citas retrasadas, productos por agotarse, corte de ayer sin cerrar, cuentas por aprobar y bloqueos de hoy.
7. **Citas**: la **Agenda** muestra una columna por barbero; toca un hueco para apartar una cita ahí (clientes que llaman o escriben) o toca una cita para marcar que llegó, moverla o cancelarla. **Bloquear horario** cierra días (vacaciones, festivos), horas (comida) o el tiempo de un barbero; si hay citas en ese tiempo, el panel te da la lista con WhatsApp para avisarles.
8. **Citas (lista)**: en la pestaña **Citas** se ve la agenda de cualquier día. Las citas de hoy también salen en **Hoy**; cuando el cliente llega se toca **Llegó** y pasa a la fila con su barbero. Si no llegó, **No vino**. El horario se cambia en la pestaña **Horario**.
9. **Horario** (solo Alejandro): arriba está el **calendario del mes**; toca uno o varios días y elige **Abrir con horario…** (por ejemplo sábado de 9 a 15 o abrir un domingo), **Cerrar** (festivos) o **Volver al normal**. Abajo está el **horario normal de la semana**. Los clientes ven ese mismo calendario al agendar, y la página principal muestra el horario de la semana.
10. **Productos**: en el diálogo de **Cobrar** se agregan los productos que se lleva el cliente; con **+ Venta** se vende sin corte. Las piezas se descuentan solas. En la pestaña **Productos** Alejandro da de alta productos, registra la mercancía que llega con **+ Entrada** y ve cuáles están por agotarse. Los productos no dan comisión al barbero.
11. En **Reportes** ve la semana o el mes: ventas, comisiones, gastos, ganancia y totales por día, por barbero y por servicio. Se puede exportar a Excel.

## Reglas de la fila y las citas
- **Turnos sin cita**: solo en horario. Se dejan de aceptar cuando la espera ya no alcanza antes de cerrar (la página ofrece agendar cita). Si el mismo teléfono vuelve a registrarse, recibe el turno que ya tenía.
- **Citas**: cada 30 min, de hoy (con 15 min de anticipación) hasta 30 días. Nunca hay más citas encimadas que barberos activos, y un barbero elegido no tiene dos a la vez. Máximo 2 citas pendientes y 1 por día por teléfono.
- **Al llegar**, el cliente toca **Ya llegué** en su cita (desde 45 min antes hasta 30 min después de su hora), o el personal toca **Llegó** en el panel. Si escanea el QR y pone su teléfono, se toma como su llegada (no queda dos veces). El panel suena y avisa cuando alguien llega solo. El cliente con cita pasa **antes** que los que llegaron sin cita. La espera que ven los demás ya cuenta las citas que están por llegar.
- Las citas que pasan 2 horas sin que nadie toque **Llegó** se marcan **no vino** solas. En el panel se ve **retrasada X min** y el botón **Recordar/Escribir** abre WhatsApp con el mensaje listo.

## Equipo: cuentas de los barberos
En **Panel → Equipo** cada tarjeta muestra en vivo qué hace el barbero (libre, atendiendo a alguien y desde hace cuántos minutos, en descanso o fuera de horario). Al tocarla se abre su **perfil**: cortes, ventas, propinas y lo que hay que pagarle (hoy, 7 días o el mes), gráfica de 14 días, próximas citas, **días libres** y la comisión con botones −/+. Al **dar de baja** a alguien con citas, el panel ofrece pasarlas a "Por asignar", quitarle el acceso y te da la lista para avisar a sus clientes. Desde ahí Alejandro también agrega barberos, les crea su cuenta (correo y contraseña), cambia contraseñas o correos, edita la comisión, da de baja y quita el acceso. Al crear una cuenta o cambiar una contraseña, el panel muestra los datos una sola vez con botones para **Copiar** o **Enviar por WhatsApp**. Cualquiera del equipo puede cambiar su propia contraseña con **Mi contraseña**.

Crear cuentas y cambiar contraseñas de otros necesita la función `equipo` (se instala una sola vez):
1. En Supabase abre **Edge Functions → Deploy a new function → Via Editor**.
2. Nombre de la función: `equipo` (exactamente así).
3. Borra el ejemplo, pega todo el contenido de `supabase/functions/equipo/index.ts` y dale **Deploy**.

La función usa la llave de administrador que Supabase le da por dentro; esa llave nunca va en las páginas. Antes de hacer algo revisa que quien la llama haya iniciado sesión y sea administrador.

## Avisos al celular (barberos)
A cada barbero le llega una notificación, aunque tenga el panel cerrado o el celular bloqueado, cuando:
- le agendan una cita (el cliente o alguien desde el panel),
- se cancela una cita suya,
- se la mueven de día u hora, o se la pasan a otro barbero (al otro le llega «Ya no es tuya»).

Las citas para «cualquier barbero» le llegan a todo el equipo. Quien hace el cambio desde el panel no recibe aviso de su propio cambio. Al tocar el aviso se abre el panel en **Citas**.

**Instalar (una sola vez):**
1. En Supabase → **SQL Editor** ejecuta `supabase/15_notificaciones.sql`.
2. En **Edge Functions → Deploy a new function → Via Editor**, nombre `avisos` (exactamente así). Pega todo `supabase/functions/avisos/index.ts` y dale **Deploy**. **Después**, en la función → pestaña **Details**, apaga **«Verify JWT with legacy secret»** (o «Enforce JWT verification») y dale **Save changes**: la función revisa por su cuenta quién la llama.
3. No hay llaves que copiar: la función crea las suyas la primera vez y las guarda en el esquema privado de la base de datos.

**Cada barbero, en su celular:**
- **Android (Chrome):** entra al panel, en **Inicio** toca **Activar avisos** y acepta el permiso. Le llega un aviso de prueba.
- **iPhone (iOS 16.4 o más nuevo):** en Safari abre el panel, toca **Compartir → Agregar a pantalla de inicio**, abre el panel desde ese ícono, entra y toca **Activar avisos**. En iPhone solo funcionan así.
- La campana de arriba muestra si están activados; desde ahí se manda una prueba o se desactivan. Al **cerrar sesión** se desactivan en ese celular.
- Si el celular lo usa otra cuenta y activa los avisos, pasan a esa cuenta.

Por privacidad, la base de datos solo le pasa a la función el número de cita (sin nombre ni teléfono); la función lee los datos y los manda cifrados al celular.

## Respaldo y mantenimiento
- **Respaldo:** en **Panel → Ajustes → Respaldo**, Alejandro descarga un Excel con todas las tablas (cortes, citas, ventas, caja, gastos, servicios, productos, equipo, horario). Guárdalo fuera de la computadora (Google Drive, USB). Si pasa una semana sin respaldar, **Inicio** lo recuerda. El Excel contiene teléfonos de clientes: no lo compartas.
- **Que Supabase no se pause:** el plan gratis pausa el proyecto tras 7 días sin actividad. La tarea `.github/workflows/mantener-activo.yml` consulta la fila pública todos los días a las 8:17 a. m. Se ve en GitHub → **Actions**. Si un día falla, GitHub manda un correo; entra a supabase.com y reactiva el proyecto.
- **Aviso de privacidad:** `privacidad.html`, enlazado desde la portada, el turno y la cita. Revísalo con quien lleve la parte legal y agrega el domicilio en `config.js` (`direccion`) para que aparezca.

## El cliente guarda su cita
En la pantalla de su cita tiene **Guarda tu cita**: Google Calendar, calendario del celular, enviársela por WhatsApp y **copiar enlace**. El enlace (`cita.html?c=…`) abre **su** cita en cualquier teléfono, para verla, avisar que llegó o cancelarla.
