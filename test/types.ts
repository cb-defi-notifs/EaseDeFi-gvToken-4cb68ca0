import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { BigNumber, Signer } from "ethers";
import {
  EaseToken,
  TokenSwap,
  IERC20,
  IVArmor,
  GvToken,
  GovernorBravoDelegate,
  Timelock,
  BribePot,
  GvTokenV2,
} from "../src/types";

export type Contracts = {
  ease: EaseToken;
  armor: IERC20;
  tokenSwap: TokenSwap;
  vArmor: IVArmor;
  gvToken: GvToken;
  bribePot: BribePot;
  gvTokenV2: GvTokenV2;
  easeGovernance: GovernorBravoDelegate;
  timelock: Timelock;
};

export type Signers = {
  easeDeployer: SignerWithAddress;
  vArmorHolder: SignerWithAddress;
  user: SignerWithAddress;
  deployer: SignerWithAddress;
  alice: SignerWithAddress;
  bob: SignerWithAddress;
  gov: SignerWithAddress;
  guardian: SignerWithAddress;
  admin: SignerWithAddress;
  briber: SignerWithAddress;
  gvToken: SignerWithAddress;
  otherAccounts: SignerWithAddress[];
};
export type Deployers = {
  tokenSwapDeployer: Signer;
  easeDeployer: Signer;
  bribePotProxyDeployer: Signer;
  gvTokenImplDeployer: Signer;
  gvTokenProxyDeployer: Signer;
  timelockDeployer: Signer;
  govDelegateDeployer: Signer;
  govDelegatorDeployer: Signer;
  bribePotImplDeployer: Signer;
};

export type MainnetAddresses = {
  armor: string;
  armorWhale: string;
  vArmor: string;
  vArmorWhale: string;
};

export type PermitSigArgs = {
  signer: SignerWithAddress;
  token: EaseToken;
  spender: string;
  value: BigNumber;
  deadline: BigNumber;
};
