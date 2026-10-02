# megahnet-lab

Laboratorio para **moldear MEGAHNET a Debian sin tocar produccion**.

El sistema nacio en XAMPP sobre Windows y se trasladó a la nube a las prisas. Quedaron
cosas a medias: temporizadores puestos a mano maquina por maquina, crons que fallan en
silencio, permisos heredados, codigo muerto conviviendo con el vivo. Este repositorio
sirve para levantar el sistema en una maquina Debian **de pruebas**, revisarlo **modulo a
modulo**, y llevar al repositorio principal solo lo que ya se probo aqui.

Repositorio del sistema: `../megahnet`

## Reglas de este laboratorio

- **Produccion no se toca desde aqui.** Nada en este repo apunta a las VMs 172.22.22.x.
- **Los datos de clientes no salen de la red.** La base de pruebas se carga desde una
  copia **anonimizada**: nombres, cedulas, correos y telefonos sustituidos, conservando
  el volumen y los casos raros (productos que faltan, correos mal escritos, facturas sin
  comprobante). Esos casos son justamente los que rompen el sistema.
- **Cada etapa se cierra antes de abrir la siguiente**, con una comprobacion que se pueda
  ejecutar de nuevo y que falle si algo se rompe.
- **Nada se da por bueno porque "arranque"**: un modulo esta listo cuando su
  comprobacion lo demuestra.

## Como se usa

La maquina de pruebas es un **VPS Debian** al que se llega por SSH. Los scripts se lanzan
desde aqui contra esa maquina; ninguno guarda credenciales.

```bash
# 1. Revisar que la maquina sirve, sin modificar nada
bash scripts/preflight.sh <ip-o-host>

# (el resto de etapas se iran anadiendo segun se revisen)
```

## Estado

| Etapa | Modulo | Estado |
|---|---|---|
| 1 | Instalacion y arranque | en preparacion |
| 2 | Clientes y contratos | pendiente |
| 3 | Facturacion automatica | pendiente |
| 4 | Factura electronica / SRI | pendiente |
| 5 | Cobros (creditos, abonos, caja) | pendiente |
| 6 | Notificaciones (correo, WhatsApp) | pendiente |
| 7 | Red / Mikrotik | pendiente |
| 8 | Panel y actualizador | pendiente |

El detalle de que se revisa en cada etapa esta en [docs/etapas.md](docs/etapas.md).
