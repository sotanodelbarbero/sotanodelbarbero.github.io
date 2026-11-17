# Barbería: registro por QR y corte de caja

**Página publicada:** https://nutrementeycuerpo.github.io/sotano-del-barbero/
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
| `supabase/10_equipo.sql` | Guarda la comisión de cada cobro (cambiar el % no altera lo ya cobrado) y la hora en que empezó cada corte. |
| `pruebas/` | Pruebas de los casos de uso de la base de datos (`cd pruebas && npm install && npm test`). No tocan tu Supabase. |
| `config.js` | URL y clave del proyecto de Supabase, y la dirección, horario y WhatsApp que se ven en la página principal. |

## Cómo ponerlo en marcha
1. Crea un proyecto en Supabase y en el **SQL Editor** ejecuta `supabase/schema.sql`. Después ejecuta `supabase/03_roles.sql`, cambiando antes `CORREO-DE-ALEJANDRO` por su correo. Ese archivo crea los roles: admin (Alejandro), barbero y cliente (QR, sin cuenta). Al final ejecuta `supabase/04_admin.sql`, que agrega comisiones, gastos, cierre de caja y el resumen de clientes, después `supabase/05_cliente.sql`, que permite al cliente seguir su turno en vivo, después `supabase/06_productos.sql`, que agrega la venta e inventario de productos (pomadas, ceras, etc.), después `supabase/07_citas.sql`, que activa las citas con día y hora, después `supabase/08_panel.sql`, que agrega los bloqueos de agenda y las citas desde el panel, después `supabase/09_calendario.sql`, que activa el calendario de apertura, y al final `supabase/10_equipo.sql`, que congela la comisión de cada cobro.
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
- **Al llegar** (botón **Llegó**), el cliente con cita pasa **antes** que los que llegaron sin cita. La espera que ven los demás ya cuenta las citas que están por llegar.
- Las citas que pasan 2 horas sin que nadie toque **Llegó** se marcan **no vino** solas. En el panel se ve **retrasada X min** y el botón **Recordar/Escribir** abre WhatsApp con el mensaje listo.

## Equipo: cuentas de los barberos
En **Panel → Equipo** cada tarjeta muestra en vivo qué hace el barbero (libre, atendiendo a alguien y desde hace cuántos minutos, en descanso o fuera de horario). Al tocarla se abre su **perfil**: cortes, ventas, propinas y lo que hay que pagarle (hoy, 7 días o el mes), gráfica de 14 días, próximas citas, **días libres** y la comisión con botones −/+. Al **dar de baja** a alguien con citas, el panel ofrece pasarlas a "Por asignar", quitarle el acceso y te da la lista para avisar a sus clientes. Desde ahí Alejandro también agrega barberos, les crea su cuenta (correo y contraseña), cambia contraseñas o correos, edita la comisión, da de baja y quita el acceso. Al crear una cuenta o cambiar una contraseña, el panel muestra los datos una sola vez con botones para **Copiar** o **Enviar por WhatsApp**. Cualquiera del equipo puede cambiar su propia contraseña con **Mi contraseña**.

Crear cuentas y cambiar contraseñas de otros necesita la función `equipo` (se instala una sola vez):
1. En Supabase abre **Edge Functions → Deploy a new function → Via Editor**.
2. Nombre de la función: `equipo` (exactamente así).
3. Borra el ejemplo, pega todo el contenido de `supabase/functions/equipo/index.ts` y dale **Deploy**.

La función usa la llave de administrador que Supabase le da por dentro; esa llave nunca va en las páginas. Antes de hacer algo revisa que quien la llama haya iniciado sesión y sea administrador.
