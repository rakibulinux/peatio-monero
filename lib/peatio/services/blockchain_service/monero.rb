# encoding: UTF-8
# frozen_string_literal: true

module BlockchainService
  class Monero < Peatio::BlockchainService::Base
    # Rough number of blocks per hour for Nxt is 6.
    def process_blockchain(blocks_limit: 6, force: false)
      latest_block = client.latest_block_number

      # Don't start process if we didn't receive new blocks.
      if blockchain.height + blockchain.min_confirmations >= latest_block && !force
        Rails.logger.info { "Skip synchronization. No new blocks detected height: #{blockchain.height}, latest_block: #{latest_block}" }
        fetch_unconfirmed_deposits
        return
      end

      from_block   = blockchain.height || 0
      to_block     = [latest_block, from_block + blocks_limit].min

      (from_block..to_block).each do |block_id|
        Rails.logger.info { "Started processing #{blockchain.key} block number #{block_id}." }

        block_data = { id: block_id }
        block_data[:deposits]    = build_deposits(client.get_transfers(
                                                          block_id - 1,
                                                          block_id,
                                                          { account_index: deposit_wallet.account_index,
                                                            deposit: true }))

        block_data[:withdrawals] = build_withdrawals(client.get_transfers(
                                                              block_id - 1,
                                                              block_id,
                                                              { account_index: withdraw_wallet.account_index,
                                                                withdraw: true }))

        save_block(block_data, latest_block)

        Rails.logger.info { "Finished processing #{blockchain.key} block number #{block_id}." }
      end
    rescue => e
      report_exception(e)
      Rails.logger.info { "Exception was raised during block processing." }
    end

    private

    def deposit_wallet
      @deposit_wallet ||= Wallet.deposit.find_by(currency: :xmr)
    end

    def withdraw_wallet
      @withdraw_wallet ||= Wallet.withdraw.find_by(currency: :xmr)
    end

    def build_deposits(txns)
      txns.each_with_object([]) do |tx, deposits|

        next if client.invalid_transaction?(tx) # skip if invalid transaction

        payment_addresses_where(address: client.to_address(tx)) do |payment_address|

          deposit_txs = client.build_transaction(tx, payment_address.currency)

          deposit_txs.fetch(:entries).each_with_index do |entry, i|

            if entry[:amount] <= payment_address.currency.min_deposit_amount
              # Currently we just skip small deposits. Custom behavior will be implemented later.
              Rails.logger.info do  "Skipped deposit with txid: #{deposit_txs[:id]} with amount: #{entry[:amount]}"\
                                     " from #{entry[:address]} in block number #{deposit_txs[:block_number]}"
              end
              next
            end

            deposits << { txid:           deposit_txs[:id],
                          address:        entry[:address],
                          amount:         entry[:amount],
                          member:         payment_address.account.member,
                          currency:       payment_address.currency,
                          txout:          i,
                          block_number:   deposit_txs[:block_number] }
          end
        end
      end
    end

    def build_withdrawals(txns)
      txns.each_with_object([]) do |tx, withdrawals|

        next if client.invalid_transaction?(tx) # skip if invalid transaction

        Withdraws::Coin
            .where(currency: currencies)
            .where(txid: client.normalize_txid(tx.fetch('txid')))
            .each do |withdraw|

          withdraw_txs = client.build_transaction(tx, withdraw.currency)
          withdraw_txs.fetch(:entries).each do |entry|
            withdrawals << {  txid:           withdraw_txs[:id],
                              rid:            entry[:address],
                              amount:         entry[:amount],
                              block_number:   withdraw_txs[:block_number] }
          end
        end
      end
    end

    def fetch_unconfirmed_deposits(txns = [])
      Rails.logger.info { "Processing unconfirmed deposits." }
      pool_txns = client.get_unconfirmed_txns({ account_index: deposit_wallet.account_index })

      # Read processed mempool tx ids because we can skip them.
      processed = Rails.cache.read("processed_#{self.class.name.underscore}_mempool_txids") || []

      # Skip processed txs.
      txns << (pool_txns - processed)
      deposits = build_deposits(txns.flatten)
      update_or_create_deposits!(deposits)

      # Store processed tx ids from mempool.
      Rails.cache.write("processed_#{self.class.name.underscore}_mempool_txids", pool_txns)
    end
  end
end


