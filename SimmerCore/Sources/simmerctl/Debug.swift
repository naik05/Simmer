import SimmerCore

func debugKeyInfo(_ smc: AppleSMC, _ names: [String]) {
    for name in names {
        let key = FourCC(name)
        do { print(name, "info:", try smc.keyInfo(key)) } catch { print(name, "info error:", error) }
        do { print(name, "read:", try smc.read(key).hex) } catch { print(name, "read error:", error) }
    }
}
