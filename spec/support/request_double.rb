# frozen_string_literal: true

# A lightweight stand-in for an ActionDispatch / Rack request, exposing only
# what Fingerprint and Guard read.
RequestDouble = Struct.new(
  :request_method, :path, :query_string, :raw_post, :headers, :cookies,
  keyword_init: true
) do
  def get_header(name)
    (headers || {})[name]
  end
end
