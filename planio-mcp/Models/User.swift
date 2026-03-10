import Foundation

struct UsersResponse: Decodable {
    let users: [User]
    let totalCount: Int
    let offset: Int
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case users
        case totalCount = "total_count"
        case offset, limit
    }
}

struct UserResponse: Decodable {
    let user: User
}

struct User: Decodable {
    let id: Int
    let login: String?
    let firstname: String?
    let lastname: String?
    let name: String?
    let mail: String?
    let apiKey: String?
    let status: Int?
    let customFields: [CustomField]?
    let createdOn: String?
    let lastLoginOn: String?

    enum CodingKeys: String, CodingKey {
        case id, login, firstname, lastname, name, mail
        case apiKey = "api_key"
        case status
        case customFields = "custom_fields"
        case createdOn = "created_on"
        case lastLoginOn = "last_login_on"
    }
}
