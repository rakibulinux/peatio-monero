# encoding: UTF-8
# frozen_string_literal: true

module WalletClient
  class Monerod < Peatio::WalletClient::Base

    def initialize(*)
      super
      @json_rpc_endpoint = URI.parse(wallet.uri + "/json_rpc")
    end


    def create_address!(options = {})
      params = { label: options[:label] }
      params.merge!(account_index: options[:account_index].to_i) unless options[:account_index].blank?
      result = json_rpc({method: 'create_address',params: params}).fetch('result')
      {
          address: normalize_address(result.fetch('address')),
          address_index: result.fetch('address_index')
      }
    end

    def load_balance!(address, currency, options = {})
      params = {}
      params.merge!(account_index: options[:account_index].to_i)
      params.merge!(address_indices: [options[:address_index].to_i]) unless options[:address_index].blank?

      json_rpc({method: 'get_balance', params: params })
          .fetch('result').fetch('balance')
          .yield_self { |amount| convert_from_base_unit(amount) }
    end

    def create_withdrawal!(issuer, recipient, amount, options = {})
      withdrawal_request(issuer, recipient, amount, options = {})
        .fetch('tx_hash')
        .yield_self { |txid| normalize_txid(txid) }
    end

    def get_txn_fee(issuer, recipient, amount, options = {})
      withdrawal_request(issuer, recipient, amount, options = {})
        .fetch('fee')
    end

    def inspect_address!(address)
      { address:  normalize_address(address),
        is_valid: true }
    end

    def normalize_address(address)
      address
    end

    def normalize_txid(txid)
      txid
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
      response['error'].tap { |error| raise Peatio::WalletClient::Error, error.inspect if error }
      response
    end

    def withdrawal_request(issuer, recipient, amount, options = {})
      params = { destinations: [{ address: recipient[:address], amount: amount }] }
      params.merge!(account_index: options[:account_index].to_i) unless options[:account_index].blank?
      params.merge!(subaddr_indices: [options[:address_index].to_i]) unless options[:address_index].blank?
      params.merge!(do_not_relay: true) if options[:do_not_relay].present?

      json_rpc({ method: 'transfer', params: params }).fetch('result')
    end
  end
end

