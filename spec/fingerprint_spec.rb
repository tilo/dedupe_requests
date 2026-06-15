# frozen_string_literal: true

require "stringio"

RSpec.describe DedupeRequests::Fingerprint do
  let(:config) { DedupeRequests::Configuration.new }

  def req(method: "POST", path: "/orders", query: "", body: "{}", auth: nil)
    RequestDouble.new(
      request_method: method, path: path, query_string: query, raw_post: body,
      headers: auth ? { "HTTP_AUTHORIZATION" => auth } : {}, cookies: {}
    )
  end

  # A request that exposes a readable body IO instead of #raw_post.
  def body_request(io)
    Struct.new(:request_method, :path, :query_string, :body, :headers, :cookies, keyword_init: true) do
      def get_header(name) = (headers || {})[name]
    end.new(request_method: "POST", path: "/x", query_string: "", body: io, headers: {}, cookies: {})
  end

  describe ".for_request" do
    it "is stable for identical requests" do
      expect(described_class.for_request(req, config)).to eq(described_class.for_request(req, config))
    end

    it "is a 64-char sha256 hex by default" do
      expect(described_class.for_request(req, config)).to match(/\A[0-9a-f]{64}\z/)
    end

    it "changes when the body changes" do
      expect(described_class.for_request(req(body: "a"), config))
        .not_to eq(described_class.for_request(req(body: "b"), config))
    end

    it "changes when the verb changes" do
      expect(described_class.for_request(req(method: "POST"), config))
        .not_to eq(described_class.for_request(req(method: "PUT"), config))
    end

    it "changes when the path changes" do
      expect(described_class.for_request(req(path: "/a"), config))
        .not_to eq(described_class.for_request(req(path: "/b"), config))
    end

    it "changes when the query string changes" do
      expect(described_class.for_request(req(query: "a=1"), config))
        .not_to eq(described_class.for_request(req(query: "a=2"), config))
    end

    it "separates callers by identity (Authorization header)" do
      expect(described_class.for_request(req(auth: "user-a"), config))
        .not_to eq(described_class.for_request(req(auth: "user-b"), config))
    end

    it "uses a full fingerprint override when configured" do
      config.fingerprint = ->(_request) { "FIXED" }
      expect(described_class.for_request(req, config)).to eq("FIXED")
    end

    it "honors a max_body_bytes cap (bodies sharing the capped prefix collide)" do
      config.max_body_bytes = 3
      a = described_class.for_request(req(body: "abcXXX"), config)
      b = described_class.for_request(req(body: "abcYYY"), config)
      expect(a).to eq(b)
    end
  end

  describe "body and caller handling" do
    it "reads and rewinds the body when raw_post is unavailable" do
      io = StringIO.new("hello")
      rackish = body_request(io)

      first = described_class.for_request(rackish, config)
      second = described_class.for_request(rackish, config)

      expect(first).to eq(second)    # the body was rewound, so the re-read matches
      expect(io.read).to eq("hello") # stream is back at the start
    end

    it "treats a missing body as empty" do
      expect(described_class.for_request(body_request(nil), config)).to match(/\A[0-9a-f]{64}\z/)
    end

    it "omits caller identity when caller_id is nil" do
      config.caller_id = nil
      expect(described_class.for_request(req, config)).to match(/\A[0-9a-f]{64}\z/)
    end

    it "reads a body that cannot be rewound" do
      no_rewind = Object.new
      def no_rewind.read = "payload"
      expect(described_class.for_request(body_request(no_rewind), config)).to match(/\A[0-9a-f]{64}\z/)
    end

    it "ignores any client-supplied Idempotency-Key header (it never affects the fingerprint)" do
      without_key = described_class.for_request(req(body: "{}"), config)
      with_key = RequestDouble.new(
        request_method: "POST", path: "/orders", query_string: "", raw_post: "{}",
        headers: { "HTTP_IDEMPOTENCY_KEY" => "abc" }, cookies: {}
      )
      expect(described_class.for_request(with_key, config)).to eq(without_key)
    end
  end

  describe ".digest" do
    it "does not collide when a value shifts across a field boundary" do
      expect(described_class.digest(%w[a bc])).not_to eq(described_class.digest(%w[ab c]))
    end

    it "supports alternate algorithms" do
      expect(described_class.digest(%w[x], :sha1)).to match(/\A[0-9a-f]{40}\z/)
      expect(described_class.digest(%w[x], :sha512)).to match(/\A[0-9a-f]{128}\z/)
      expect(described_class.digest(%w[x], :md5)).to match(/\A[0-9a-f]{32}\z/)
    end

    it "accepts a callable algorithm" do
      expect(described_class.digest(%w[x], ->(d) { "len#{d.bytesize}" })).to start_with("len")
    end

    it "raises on an unknown algorithm" do
      expect { described_class.digest(%w[x], :nope) }.to raise_error(ArgumentError)
    end
  end
end
