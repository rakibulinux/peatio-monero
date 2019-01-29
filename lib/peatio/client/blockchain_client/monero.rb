# encoding: UTF-8
# frozen_string_literal: true

module BlockchainClient
  class Monero < Peatio::BlockchainClient::Base
    def initialize(*)
      super
      @json_rpc_call_id  = 0
      @json_rpc_endpoint = URI.parse(blockchain.server + "/json_rpc")
    end

    def endpoint
      @json_rpc_endpoint
    end

    def latest_block_number
      Rails.cache.fetch "latest_#{self.class.name.underscore}_block_number", expires_in: 5.seconds do
        json_rpc({method: 'get_height', params: {}}).fetch('result').fetch('height')
      end
    end

    def load_balance!(address, currency, options = {})
      params = {account_index: options[:account_index], address_indices: [0]}
      json_rpc({method: 'get_balance', params: params})
          .fetch('balance')
          .yield_self { |amount| convert_from_base_unit(amount, currency) }
    end

    def get_transfers(min_height, max_height, options = {})
      params = { filter_by_height: true,
                 min_height: min_height,
                 max_height: max_height }
      params.merge!(in: true, out:true) if options[:deposit]
      params.merge!(out:true) if options[:withdraw]
      params.merge!(account_index: options[:account_index].to_i ) unless options[:account_index].blank?

      build_transfers(json_rpc({ method: 'get_transfers',params: params }).fetch("result"))
    end

    def get_unconfirmed_txns(options = {})
      params = { pool: true }
      params.merge!(account_index: options[:account_index].to_i) unless options[:account_index].blank?
      build_transfers(json_rpc({ method: 'get_transfers', params: params }).fetch("result"))
    end

    def build_transaction(tx, currency)
      entries = tx.fetch('destinations').map.with_index do |destination, index|
        { amount:  convert_from_base_unit(destination.fetch('amount'), currency),
          address: normalize_address(destination.fetch("address")),
          txout:   index }
      end

      { id:            normalize_txid(tx.fetch('txid')),
        block_number:  tx.fetch('height') == 0 ? nil : tx.fetch('height'),
        entries:       entries
      }
    end

    def to_address(tx)
      tx.fetch('destinations').map do |destination|
        normalize_address(destination.fetch("address"))
      end
    end

    def valid_transaction?(tx)
      ['false',false].include?(tx['double_spend_seen'])
    end

    def invalid_transaction?(tx)
      !valid_transaction?(tx)
    end

    protected

    def connection
      Faraday.new(@json_rpc_endpoint).tap do |connection|
        unless @json_rpc_endpoint.user.blank?
          connection.basic_auth(@json_rpc_endpoint.user, @json_rpc_endpoint.password)
        end
      end
    end
    memoize :connection

    def json_rpc(params = {})
      response = connection.post do |req|
        req.body = params.to_json
      end
      response.assert_success!
      response = JSON.parse(response.body)
      response['error'].tap { |error| raise Peatio::BlockchainClient::Error, error.inspect if error }
      response
    end

    def build_transfers(result)
      txns = []
      result.fetch("out", []).each do |out_txn|
        next if out_txn["amount"] <= 0
        txns << out_txn.slice("height","fee","double_spend_seen","txid","destinations")
      end
      result.fetch("in", []).each do |in_txn|
        next if in_txn["amount"] <= 0
        txns << build_data(in_txn)
      end
      result.fetch("pool", []).each do |pool_txn|
        next if pool_txn["amount"] <= 0
        txns << build_data(pool_txn)
      end
      txns.compact
    end

    def build_data(tx)
      deposit = tx.slice("height","fee","double_spend_seen","txid")
      deposit.merge!("destinations" => [{"address" => tx["address"], "amount" => tx["amount"]}])
    end
  end
end
