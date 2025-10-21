## KipuBankV3

### Mejoras Realizadas y Justificación

Esta versión de KipuBankV3 implementa una arquitectura modular y segura para la gestión de depósitos y retiros en USDC, permitiendo la conversión automática de ETH y otros tokens ERC20 mediante Uniswap V4. Se han incorporado las siguientes mejoras:

- **Seguridad:** Uso de `ReentrancyGuard` y la librería `SafeERC20` para proteger contra ataques de reentrancy y transferencias inseguras.
- **Roles y permisos:** Implementación de control de acceso granular con roles de administrador, operador y emergencia usando OpenZeppelin AccessControl.
- **Interoperabilidad:** Integración con Chainlink para precios de ETH/USD y Uniswap UniversalRouter para swaps automáticos.
- **Flexibilidad:** Parámetros configurables como mínimo de depósito, comisión de retiro, periodo de bloqueo y límite global de depósitos.
- **Gestión de cuentas:** Cada usuario tiene su propia cuenta, historial de depósitos/retiros y protección contra operaciones no autorizadas.

Estas mejoras buscan maximizar la seguridad, escalabilidad y facilidad de uso del contrato, facilitando la integración con otros protocolos y la administración eficiente de fondos.

### Instrucciones de Despliegue e Interacción

1. **Despliegue:**
	- Clona el repositorio y asegúrate de tener los submódulos actualizados (`git submodule update --init --recursive`).
	- Configura las direcciones de los contratos externos (Chainlink, Uniswap, Permit2, WETH9) en el script de despliegue.
	- Usa Foundry para compilar y desplegar:
	  ```sh
	  forge build
	  forge script script/KipuBankV3Script.s.sol --rpc-url <RPC_URL> --broadcast --verify
	  ```
	- El script de ejemplo crea una cuenta para el deployer tras el despliegue.

2. **Interacción:**
	- Los usuarios deben crear una cuenta con `createAccount()` antes de depositar.
	- Para depositar USDC, llama a `deposit(USDC, amount)`; para ETH o cualquier ERC20, llama a `deposit(tokenAddress, amount)`.
	- Los retiros se realizan con `withdraw(amount)`, sujeto a periodo de bloqueo y comisión.
	- El administrador puede ajustar parámetros y retirar comisiones acumuladas.

### Notas de Diseño y Trade-offs

- **Swap UniversalRouter:** El contrato delega la lógica de conversión de tokens a Uniswap UniversalRouter, lo que simplifica la gestión de swaps pero requiere que los tokens sean compatibles y que el router esté correctamente configurado.
- **Gestión de WETH9:** Se utiliza una instancia constante de WETH9 para facilitar la conversión de ETH a ERC20, evitando errores comunes de dirección y permitiendo mayor interoperabilidad.
- **Control de acceso:** El uso de roles permite una administración flexible, pero requiere una gestión cuidadosa de permisos para evitar riesgos de seguridad.
- **Parámetros configurables:** Permitir la modificación de parámetros críticos (mínimo de depósito, comisión, periodo de bloqueo) otorga flexibilidad pero puede introducir riesgos si no se controla adecuadamente.
- **Trade-off entre simplicidad y extensibilidad:** Se priorizó la simplicidad en la lógica de depósitos/retiros y swaps, dejando la extensibilidad para futuras versiones (por ejemplo, soporte para más tokens, pools dinámicos, etc).

---
Para dudas o mejoras, consulta la documentación interna y los comentarios en el código fuente.

```shell
$ forge --help
$ anvil --help
$ cast --help
```
