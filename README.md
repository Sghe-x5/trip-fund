# TripFund

Сбор ERC-20 на поездку команды. Проект включает основное задание и бонус с обновлением V1 до V2 через Transparent Proxy OpenZeppelin 5.x.

## Версии и установка

- Solidity 0.8.24, EVM Cancun.
- Foundry 1.5.0.
- Node.js 22, npm 10 или новее.
- OpenZeppelin Contracts 5.0.2.
- OpenZeppelin Upgrades Core 1.44.2.
- forge-std 1.9.7 включён в `lib/forge-std` с исходной лицензией.

Установите Foundry по официальной инструкции на getfoundry.sh/introduction/installation/, затем выполните команды ниже.

```sh
foundryup --install v1.5.0
npm ci
forge build
forge test
npm run validate-upgrade
```

Команды выполняются из корня проекта. `npm ci` восстанавливает точные зависимости из `package-lock.json`; отдельный `forge install` не нужен. Первый запуск Forge загружает Solidity 0.8.24.

Полная проверка, включая форматирование, тесты и совместимость обновления выполняется командой ниже.

```sh
npm run check
```

GitHub Actions запускает ту же проверку при push и pull request. Для сдачи загрузите содержимое проекта в GitHub вместе с `lib`, `package-lock.json` и скрытой директорией `.github`. Сборочные артефакты и `node_modules` не нужны.

## Архитектура

| Файл | Назначение |
| --- | --- |
| `src/TripFundCore.sol` | Общие storage, проверки, взносы, вывод и возвраты |
| `src/TripFund.sol` | Основная версия с параметрами в конструкторе |
| `src/TripFundV1.sol` | Инициализируемая реализация для Transparent Proxy |
| `src/TripFundV2.sol` | V1 с дополнительным `contributeFor` без новых полей storage |
| `src/TripToken.sol` | Обычный OpenZeppelin ERC20 с первоначальной эмиссией |
| `test/TripFund.t.sol` | Общая поведенческая проверка основной версии, V1 и V2 |
| `test/TripFundUpgrade.t.sol` | Обновление существующего прокси, права и взносы за друга |
| `script/Deploy.s.sol` | Развёртывание основной версии или V1 через прокси |
| `script/Upgrade.s.sol` | Обновление существующего прокси до V2 до дедлайна |

`goal`, `deadline`, `token` и `organizer` не имеют сеттеров. `deadline` задаётся в секундах Unix; `goal` и суммы взносов задаются в минимальных единицах токена. Для TRIP с 18 decimals значение `1000000000000000000` означает один токен.

До дедлайна принимаются положительные взносы. Начиная ровно с дедлайна успешный сбор допускает единственный вывод организатором всей учтённой суммы. При неуспешном сборе каждый получатель вклада самостоятельно возвращает свой полный вклад. `totalRaised` сохраняет историческую сумму и не уменьшается после выплат. При возврате обнуляется только вклад получателя.

Прямые переводы не учитываются и остаются в контракте после всех положенных выплат. Они не превращают неуспешный сбор в успешный. Функций распределения или извлечения таких средств нет.

Все переводы выполняются через SafeERC20. Учёт меняется перед внешним вызовом и полностью откатывается при ошибке. Общий запрет повторного входа защищает операции, включая `contributeFor`. Токен сбора должен быть обычным ERC-20 без комиссии на перевод и rebasing, как в условии.

## Проверки задания

| Критерий | Проверка |
| --- | --- |
| Параметры и запреты при создании | `testParameters`, `testRejects*` |
| Два участника, повторные взносы и событие | `testTwoParticipantsAndRepeatedContributions`, `testContributionEvent` |
| Ноль, баланс, allowance и откат | `testZeroAmountRollsBack`, `testInsufficient*`, `testFalseTransferFromRollsBack` |
| Граница дедлайна и запрет досрочных выплат | `testContribution*Deadline*`, `testNoEarly*` |
| Ровно цель, выше цели, чужой и повторный вывод | `testWithdraw*`, `testOnlyOrganizerCanWithdraw`, `testCannotWithdraw*` |
| Полные независимые возвраты и неверный исход | `testIndependentFullRefundsAtDeadline`, `testCannotRefund*` |
| Прямые переводы | `testDirectTransfer*` |
| Откат неудачной выплаты и успешная повторная попытка | `testWithdrawTransferFailureRestoresFlagAndCanRetry`, `testRefundTransferFailureRestoresContributionAndCanRetry` |
| Защита от повторного входа | `testReentrant*` |
| Разные суммы и оба исхода | `testFuzzContributionsAndSettlement`, 256 наборов для каждой версии |
| Прокси, сохранение всех данных и возврат другу | `testUpgradePreservesAllStateAndRefundsFriend` |
| Права обновления и запрет инициализации | `testOnlyProxyAdminOwnerCanUpgrade`, `testDirectProxyUpgradeIsRejected`, `test*Initialization*`, `testProxyCannotBeInitializedTwiceBeforeOrAfterUpgrade` |
| Взнос за друга, событие, плательщик и проверки | `testContributeFor*` |
| Совместимость storage при обновлении V1 до V2 | `npm run validate-upgrade` |

## Пример approve и взноса

`TOKEN` содержит адрес ERC-20. `FUND` содержит адрес TripFund либо адрес прокси для V1/V2. `RPC_URL` содержит RPC узла. `participant` обозначает заранее импортированный аккаунт Foundry keystore.

```sh
cast send "$TOKEN" 'approve(address,uint256)' "$FUND" 1000000000000000000 --rpc-url "$RPC_URL" --account participant
cast send "$FUND" 'contribute(uint256)' 1000000000000000000 --rpc-url "$RPC_URL" --account participant
cast call "$FUND" 'totalRaised()(uint256)' --rpc-url "$RPC_URL"
```

В V2 плательщик может направить взнос другому адресу.

```sh
cast send "$TOKEN" 'approve(address,uint256)' "$FUND" 1000000000000000000 --rpc-url "$RPC_URL" --account participant
cast send "$FUND" 'contributeFor(address,uint256)' "$BENEFICIARY" 1000000000000000000 --rpc-url "$RPC_URL" --account participant
```

Списываются средства аккаунта `participant`; право возврата получает `BENEFICIARY`. Для прокси spender в `approve` всегда адрес прокси. После дедлайна можно вывести средства организатору.

```sh
cast send "$FUND" 'withdraw()' --rpc-url "$RPC_URL" --account organizer
```

При неуспехе вместо вывода каждый получатель вклада вызывает возврат.

```sh
cast send "$FUND" 'refund()' --rpc-url "$RPC_URL" --account beneficiary
```

## Развёртывание

Задайте `TOKEN`, `ORGANIZER`, `GOAL`, `DEADLINE` в окружении. Токен для локального узла можно создать следующей командой.

```sh
forge create TripToken --constructor-args "$RECIPIENT" 1000000000000000000000000 --rpc-url "$RPC_URL" --account deployer --broadcast
```

Основная версия разворачивается следующей командой.

```sh
forge script script/Deploy.s.sol --target-contract DeployTripFund --rpc-url "$RPC_URL" --account deployer --broadcast
```

Для бонуса дополнительно задайте `PROXY_ADMIN_OWNER` и сразу разверните V1 через прокси с атомарной инициализацией.

```sh
forge script script/Deploy.s.sol --target-contract DeployTripFundProxy --rpc-url "$RPC_URL" --account deployer --broadcast
```

OpenZeppelin 5.x создаёт отдельный ProxyAdmin внутри конструктора TransparentUpgradeableProxy. `PROXY_ADMIN_OWNER` задаёт владельца создаваемого ProxyAdmin. Организатор и владелец администратора могут быть разными адресами.

Задайте `PROXY` адресом созданного прокси и получите адрес ProxyAdmin из EIP-1967.

```sh
cast admin "$PROXY" --rpc-url "$RPC_URL"
```

Сохраните результат в `PROXY_ADMIN`. До дедлайна проверьте совместимость и обновите тот же прокси аккаунтом владельца ProxyAdmin.

```sh
npm run validate-upgrade
forge script script/Upgrade.s.sol --target-contract UpgradeTripFund --rpc-url "$RPC_URL" --account proxy-admin-owner --broadcast
```

Новый вызов `initialize` не нужен и запрещён. Адрес прокси, токены, разрешения, параметры и накопленные вклады сохраняются.

## Проверка OpenZeppelin Upgrades

Команда `npm run validate-upgrade` выполняет чистую сборку с `build_info` и `storageLayout`, проверяет безопасность V1 и затем V2 с явно указанной V1 в качестве эталона и обязательным `--requireReference`. Проверка storage не отключается.

Единственное разрешение `--unsafeAllow constructor` нужно для конструктора V1, который вызывает только `_disableInitializers()`. V2 наследует этот конструктор. Оба запрета прямой инициализации дополнительно проверяются тестом. Аннотации в комментариях не используются, эталон и разрешение передаются инструменту явно.

Документация 

- Transparent Proxy и ProxyAdmin в docs.openzeppelin.com/contracts/5.x/api/proxy
- OpenZeppelin Upgrades Core CLI в docs.openzeppelin.com/upgrades-plugins/api-core
