
// ssstore: preserve every component of a pushed batch. The upstream v0.1.68
// implementation returns inside the row loop and drops all following rows.
fn ssstore_parse_batch(rows: Vec<Value>) -> Option<SysmontapSample> {
    let mut result = SysmontapSample { processes: None, system: None, system_cpu_usage: None };
    for row in rows {
        let Some(dict) = row.into_dictionary() else { continue };
        let sample = parse_sample_dict(dict);
        if let Some(processes) = sample.processes {
            result.processes.get_or_insert_with(Dictionary::new).extend(processes);
        }
        if sample.system.is_some() { result.system = sample.system; }
        if let Some(cpu) = sample.system_cpu_usage {
            result.system_cpu_usage.get_or_insert_with(Dictionary::new).extend(cpu);
        }
    }
    if result.processes.is_some() || result.system.is_some() || result.system_cpu_usage.is_some() {
        Some(result)
    } else { None }
}

#[cfg(test)]
mod ssstore_batch_tests {
    use super::*;
    fn row(key: &str, value: Value) -> Value {
        let mut dict = Dictionary::new(); dict.insert(key.into(), value); Value::Dictionary(dict)
    }
    #[test]
    fn ssstore_batch_keeps_system_cpu_and_all_process_rows() {
        let mut cpu = Dictionary::new(); cpu.insert("CPU_TotalLoad".into(), Value::Real(12.5));
        let mut one = Dictionary::new(); one.insert("11".into(), Value::Array(vec![Value::Real(25.0)]));
        let mut two = Dictionary::new(); two.insert("22".into(), Value::Array(vec![Value::Real(50.0)]));
        let result = ssstore_parse_batch(vec![
            row("System", Value::Array(vec![Value::Integer(100i64.into())])),
            row("SystemCPUUsage", Value::Dictionary(cpu)),
            row("Processes", Value::Dictionary(one)), row("Processes", Value::Dictionary(two)),
        ]).unwrap();
        assert_eq!(result.processes.unwrap().len(), 2);
        assert_eq!(result.system.unwrap().len(), 1);
        assert_eq!(result.system_cpu_usage.unwrap()["CPU_TotalLoad"].as_real(), Some(12.5));
    }
    #[test]
    fn ssstore_batch_empty_process_list_is_a_valid_clear() {
        assert!(ssstore_parse_batch(vec![row("Processes", Value::Dictionary(Dictionary::new()))]).unwrap().processes.unwrap().is_empty());
        assert!(ssstore_parse_batch(vec![Value::String("ack".into())]).is_none());
    }
}
