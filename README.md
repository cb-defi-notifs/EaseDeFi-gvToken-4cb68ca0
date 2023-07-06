# Growing Vote Tokenomics

### [Documentation](https://docs.google.com/document/d/1U4gdkx_Qen8iApCc0C5zSi3PrDfbn_yoBM9RWaeaqTw/edit)

## Mainnet Addresses

- tokenSwap: [0xEA5edef17986EAbb7333bacdC9E2F574C7Fe6935](https://etherscan.io/address/0xEA5edef17986EAbb7333bacdC9E2F574C7Fe6935),
- easeToken: [0xEa5eDef1287AfDF9Eb8A46f9773AbFc10820c61c](https://etherscan.io/address/0xEa5eDef1287AfDF9Eb8A46f9773AbFc10820c61c),
- bribePot: [0xEA5EdeF17C9be57228389962ba50b98397f1E28C](https://etherscan.io/address/0xEA5EdeF17C9be57228389962ba50b98397f1E28C),
- gvToken: [0xEa5edeF1eDB2f47B9637c029A6aC3b80a7ae1550](https://etherscan.io/address/0xEa5edeF1eDB2f47B9637c029A6aC3b80a7ae1550),
- timelock: [0xEA5edEf1401e8C312c797c27a9842e03Eb0e557a](https://etherscan.io/address/0xEA5edEf1401e8C312c797c27a9842e03Eb0e557a),
- governance: [0xEA5eDeF17c4FCE9C120790F3c54D6E04823dE587](https://etherscan.io/address/0xEA5eDeF17c4FCE9C120790F3c54D6E04823dE587),

## Tests and Deployment

1. Clone this repo `git@github.com:EaseDeFi/gvToken.git`
2. Install dependencies `cd gvToken` && `npm install`
3. Change `.env.example` to `.env` and update the variables
4. Compile contracts - `npm run compile`
5. Run tests - `npm test` (_Make sure the block number in `.env` is 14740073_)
6. Deploy contracts:-

   - DEV DEVELOPMENT

     - Forked Mainnet Hardhat: `npx hardhat run scripts/devDeploy.ts`
     - Locally Forked Node: `npx hardhat node` && `npx hardhat run scripts/devDeploy.ts --network localhost`
     - Tenderly Fork - (_Note: make sure account MAINNET_PRIVATE_KEY in .env has at least 20K armor and 1 eth on that tenderly fork_) `npx hardhat run scripts/devDeploy.ts --network tenderly`

   - PROD
     - Forked Mainnet Hardhat: `npx hardhat run scripts/deploy.ts`
     - Locally Forked Node: `npx hardhat node` && `npx hardhat run scripts/deploy.ts --network localhost`
     - Other Networks: `npx hardhat run scripts/deploy.ts --network networkName`
