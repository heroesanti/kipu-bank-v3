# 🛡️ Informe de Análisis de Amenazas: KipuBankV3

---

## 1. Descripción General del Protocolo

KipuBankV3 es un contrato de **banca descentralizada** diseñado para permitir a los usuarios depositar, retirar y gestionar sus tokens. El protocolo estandariza todos los depósitos a **USDC (6 decimales)** utilizando un *router* de *swaps* externo.

### Componentes Clave

| Componente | Descripción |
| :--- | :--- |
| **Roles** | `ADMIN_ROLE`, `OPERATOR_ROLE`, `EMERGENCY_ROLE` (control de acceso jerárquico). |
| **Depósitos** | Mínimo: **100 USDC**. Límite global: **1M USDC** (configurable). |
| **Retiros** | Límite por transacción: **200 USDC**. Comisión del **5%**. Período de bloqueo de **1 día**. |
| **Swaps** | Utiliza **UniversalRouter (Uniswap V4)** para convertir tokens (ETH, ERC20) a USDC. |
| **Oracle** | Chainlink ETH/USD para precios (actualmente no usado en lógica crítica). |
| **Emergencia** | Retiro sin comisiones ni bloqueo (solo para `EMERGENCY_ROLE` o dueño de cuenta). |

### Flujo de Trabajo Principal

1.  **Creación de Cuenta**: `createAccount()` (requerido).
2.  **Depósito**:
    * **ETH** → Wrap a WETH → Swap a USDC.
    * **USDC** → Transferencia directa.
    * **Otro ERC20** → Swap a USDC vía UniversalRouter.
3.  **Retiro**:
    * Verifica bloqueo, saldo y límite.
    * Aplica comisión del **5%** y envía USDC al usuario.
4.  **Administración**:
    * Ajuste de parámetros (`minimumDeposit`, `withdrawalFee`, etc.).
    * Retiro de comisiones acumuladas (`withdrawFees`).

---

## 2. Evaluación de Madurez del Protocolo 👶

El protocolo presenta una **madurez baja** con **riesgos críticos** debido a la falta de pruebas rigurosas y centralización de roles.

| Categoría | Estado Actual | Debilidades | Pasos para Madurez |
| :--- | :--- | :--- | :--- |
| **Cobertura de Pruebas** | Insuficiente (solo pruebas básicas para `Counter.sol`). | ❌ Sin pruebas para lógica crítica (swaps, retiros, roles). | **Escribir pruebas unitarias (Foundry)** para todos los métodos. Pruebas de *fuzzing* para *edge cases*. |
| **Métodos de Prueba** | Ausentes. | ❌ Sin verificación de invariantes o pruebas de integración. | Usar **Foundry** para pruebas avanzadas (*fuzzing*, *console.logs*, *mocks*). |
| **Documentación** | Mínima (solo comentarios). | ❌ Falta especificación formal, NatSpec, y guías de arquitectura/riesgos. | Redactar **README completo** y usar **NatSpec** (`@notice`, `@param`). |
| **Roles y Poderes** | Parcialmente definido. | ❌ `ADMIN_ROLE` puede extraer fondos arbitrarios (`withdrawFees`). `EMERGENCY_ROLE` sin restricciones de tiempo/uso. | Implementar **Multisig** para funciones críticas. Limitar poderes de emergencia. |
| **Invariantes** | No documentados (implícitos). | ❌ Sin monitoreo en tiempo real. | Usar **OpenZeppelin Defender** o *scripts off-chain* para validar invariantes. |

### Riesgos Críticos por Madurez Insuficiente

* **Falta de Pruebas**: El fallo en `UniversalRouter.execute()` podría resultar en **pérdida de fondos** si el *swap* no revierte correctamente.
* **Centralización de Roles**: El `ADMIN_ROLE` puede cambiar el *priceFeed* a un *oracle* malicioso, permitiendo la **manipulación de precios**.
* **Lógica de Swap Incompleta**: `_swapExactInputSingle` **no valida** el `amountOut` real. Los usuarios podrían recibir menos USDC de lo esperado.

---

## 3. Vectores de Ataque y Modelo de Amenazas 💥

| Ataque | Superficie / Escenario | Mitigación Recomendada |
| :--- | :--- | :--- |
| **Ataque 1: Reentrancy** (Swaps Maliciosos) | La función `deposit` llama a `UniversalRouter.execute`, que podría invocar *callbacks* a contratos maliciosos. | Usar **`nonReentrant`** en todas las funciones con interacciones externas. Validar que `tokenIn` no sea un contrato malicioso (ej: Lista Blanca). |
| **Ataque 2: Manipulación de Precios** (Oracle) | Un admin podría cambiar `ethUsdPriceFeed` a un *oracle* manipulado en futuras versiones. | Usar **Oracle Fallback** (ej: Chainlink + Uniswap TWAP). Restringir cambios de *oracle* a un **DAO o Multisig**. |
| **Ataque 3: Front-Running** en `withdrawFees` | Un admin detecta comisiones acumuladas, y un usuario deposita una gran suma. El admin ejecuta `withdrawFees` antes de actualizar `totalDeposits`. | Usar **Timelock** para `withdrawFees`. Implementar *snapshots* para validar `totalDeposits` vs. el balance real. |
| **Ataque 4: Abuso de `emergencyWithdraw`** | Cualquier usuario puede usar `emergencyWithdraw` sin restricciones, potencialmente vaciando el contrato. | **Limitar** `emergencyWithdraw` a un **%** del `totalDeposits` (ej: máximo 10%). Requerir *governance* para emergencias masivas. |
| **Ataque 5: Swap Fallido sin Reversión** | `_swapExactInputSingle` no valida el `amountOut` real. Un *swap* falla (ej: *slippage* alto), y el contrato no revierte. | **Validar el balance de USDC** antes y después del *swap* (`IERC20(USDC).balanceOf(address(this))`) para confirmar el `amountOut`. |

---

## 4. Especificación de Invariantes 📏

| Invariante | Descripción | Violación/Impacto |
| :--- | :--- | :--- |
| **1: `totalDeposits <= bankCap`** | El total de depósitos nunca debe exceder el límite global. | Si se viola: **Quiebra del protocolo** (no se aceptan más depósitos). |
| **2: `USDC.balanceOf(this) >= totalDeposits`** | El contrato siempre debe tener al menos el valor de `totalDeposits` en USDC. | Si se viola: **Pérdida de fondos de usuarios** (no pueden retirar). |
| **3: `account.balance.amount >= 0`** | El saldo de un usuario nunca puede ser negativo. | Si se viola: Usuarios con saldos negativos podrían **drenar fondos** de otros. |
| **4: `withdrawalFee <= 10%`** | La comisión de retiro no debe exceder el límite *hardcodeado*. | Si se viola: **Explotación económica**, pérdida masiva de confianza. |
| **5: `lockPeriod` se respeta** | Los fondos no pueden retirarse antes de `lastDepositTimestamp + lockPeriod`. | Si se viola: Usuarios retiran fondos prematuramente, **rompiendo el modelo económico**. |

---

## 6. Recomendaciones 💡

### Para Validar Invariantes (Código)

* **Invariante 1 (Capacidad)**: Añadir `require(totalDeposits + usdcAmount <= bankCap, "Bank capacity exceeded");` en `deposit()`.
* **Invariante 2 (Solvencia)**: En `withdraw` y `emergencyWithdraw`, validar:
    ```solidity
    uint256 contractBalance = IERC20(USDC).balanceOf(address(this));
    require(contractBalance >= totalDeposits, "Insufficient USDC balance");
    ```

### Mejoras Generales

| Área | Recomendación |
| :--- | :--- |
| **Pruebas** | Escribir pruebas para **Swaps fallidos**, **Edge cases** (depósitos/retiros de 0/máximos), y **Roles** con permisos insuficientes. |
| **Seguridad** | Auditar **UniversalRouter** y **Permit2** (dependencias externas críticas). Usar **Slither** para análisis estático. |
| **Gobernanza** | Reemplazar `ADMIN_ROLE` unipersonal con un **Multisig** (Gnosis Safe). Implementar **Timelocks** para cambios críticos. |
| **Economía** | Añadir límites dinámicos para `emergencyWithdraw` (ej: máximo **10%** del TVL). |
| **Monitoreo** | Usar **Tenderly** u **OpenZeppelin Defender** para alertas en tiempo real sobre invariantes violados. |

---

## 7. Conclusión y Próximos Pasos 🚀

El estado actual del protocolo presenta un **Riesgo Alto** y una **Madurez Baja**. La combinación de dependencias externas no auditadas, falta de pruebas, y centralización de roles lo hace **vulnerable a exploits** con riesgo de pérdida total de fondos.

### Próximos Pasos para Producción

1.  **Pruebas Rigurosas**: Escribir **100% de cobertura** (Foundry). Probar escenarios adversos (reentrancy, front-running, swaps fallidos).
2.  **Auditoría Externa**: Contratar un equipo profesional para auditar la **lógica de swaps**, el **control de acceso** y los **invariantes económicos**.
3.  **Mejoras de Código**: Implementar el patrón **checks-effects-interactions** y añadir **eventos detallados** (ej: `SwapFailed`).
4.  **Despliegue Gradual**: Lanzar en *testnet* y usar **bug bounty** antes de considerar *mainnet*.

### Recomendación Final

**No desplegar en mainnet** hasta completar las pruebas rigurosas, implementar el **Multisig/DAO** para gobernanza y recibir una auditoría externa positiva. La **prioridad es la seguridad** sobre la velocidad.

---

¿Te gustaría que profundice en la implementación de alguna de estas **mitigaciones** específicas, como el uso de un Multisig para el `ADMIN_ROLE`?