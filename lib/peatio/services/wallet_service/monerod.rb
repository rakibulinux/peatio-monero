# encoding: UTF-8
# frozen_string_literal: true

module WalletService
  class Monerod < Peatio::WalletService::Base

    def create_address(options = {})
      options.merge!(account_index: wallet.account_index)
      @client.create_address!(options)
    end

    def collect_deposit!(deposit, options={})
      pa = deposit.account.payment_address

      spread_hash = spread_deposit(deposit)
      spread_hash.map do |address, amount|

        fee = client.get_txn_fee(
                { address: pa.address, secret: pa.secret },
                { address: address },
                amount.to_i,
                { account_index: wallet.account_index,
                  address_index: pa.details["address_index"],
                  do_not_relay: true }
            )

        amount *= deposit.currency.base_factor
        amount -= fee

        client.create_withdrawal!(
            { address: pa.address, secret: pa.secret },
            { address: address },
            amount.to_i,
            { account_index: wallet.account_index,
              address_index: pa.details["address_index"] }
        )
      end
    end

    def build_withdrawal!(withdraw, options = {})
      client.create_withdrawal!(
          { address: wallet.address, secret: wallet.secret },
          { address: withdraw.rid },
          withdraw.amount_to_base_unit!,
          { account_index: wallet.account_index,
            address_index: wallet.address_index }
      )
    end

    def load_balance(address, currency, options = {})
      client.load_balance!(address,
                           currency,
                           { account_index: wallet.account_index,
                             address_index: wallet.address_index })
    end
  end
end
